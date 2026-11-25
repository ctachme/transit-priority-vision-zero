# =====================================================================================
# BusStopTimeModel.R — shared street-derived bus running-time and dwell model
# Used by GenerateGridAndLocal.Rmd (grid express/frequent/local), GenerateNodeGTFS.Rmd (node
# express) and GenerateNodeGTFS.Rmd (node feeders), so every designed network uses one model.
#
# Pipeline (mirrors the grid build):
#   gst_load_refs(p)                    -> streets(+street-grid), full_signals, osm_roads, traffic counts
#   gst_prep(routes_sf, refs, p)        -> sub-segments (speed + merge gate), TSP-conflict signals
#   gst_classify_stops(stops_sf, ...)   -> per-stop signalized / tsp_conflict / aadt / d_re / merge gate
#   gst_route_stop_times(rid, geom, cand_stops, prepped, p) -> stop_times (d0/d1) for one route
#
# Data sources (all public): Seattle Streets centerlines (posted speed, arterial class),
# SDOT Traffic Signals, SDOT 2022 Traffic Flow Counts + WSDOT traffic counts (AADT for the
# re-entry gap-acceptance delay), and the OpenStreetMap Washington extract (highway class
# for alignment pieces off the city street network, e.g. freeways and ramps).
#
# Model: running time = Sigma length/speed with a 30 mph arterial / 20 mph residential floor
# that posted SPEEDLIMIT can raise; + accel/decel lost time (cutaway); dwell = signalized 8 s /
# TSP-conflict 15 s / non-signalized (base 8 + gap-acceptance d_re, gated to 0 where no curbside
# GP lane remains beside a bus lane); + 15 s per TSP-conflict signal crossed without stopping.
# =====================================================================================

suppressMessages({ library(sf); library(dplyr) })

MPH_FTS <- 5280 / 3600
MPH_MS  <- 0.44704
SEGDIR_BRG <- c(N = 0, NE = 45, E = 90, SE = 135, S = 180, SW = 225, W = 270, NW = 315)

# OSM highway class -> free-flow speed (mph), used ONLY where Seattle_Streets has no segment
# (freeways, ramps, state highways). Seattle_Streets covers city streets with posted speeds + floors.
OSM_HW_SPEED <- c(motorway = 60, motorway_link = 45, trunk = 50, trunk_link = 35,
                  primary = 35, primary_link = 30, secondary = 30, secondary_link = 25,
                  tertiary = 25, tertiary_link = 20, residential = 20, living_street = 15,
                  unclassified = 20, service = 15, track = 15)

lost_time      <- function(v_mph, a_a, a_d) { v <- v_mph * MPH_MS; (v / 2) * (1/a_a + 1/a_d) }
bearing180     <- function(dx, dy) { b <- atan2(dy, dx) * 180 / pi; b %% 180 }
bearing_diff   <- function(a, b) { d <- abs(a - b) %% 180; pmin(d, 180 - d) }
compass_bearing<- function(dx, dy) (90 - atan2(dy, dx) * 180 / pi) %% 360
ang_diff360    <- function(a, b) { d <- abs(a - b) %% 360; pmin(d, 360 - d) }
secs_to_hms    <- function(s) sprintf("%02d:%02d:%02d", s %/% 3600, (s %% 3600) %/% 60, s %% 60)

to_single_line <- function(g) {
  g <- sf::st_zm(sf::st_geometry(g), drop = TRUE)
  g <- tryCatch(sf::st_line_merge(g), error = function(e) g)
  if (as.character(sf::st_geometry_type(g)[1]) == "MULTILINESTRING") {
    parts <- suppressWarnings(sf::st_cast(g, "LINESTRING"))
    parts[which.max(as.numeric(sf::st_length(parts)))]
  } else g[1]
}

densify_coords <- function(line_sfc, seg_ft) {
  d <- sf::st_segmentize(line_sfc, dfMaxLength = seg_ft)
  xy <- sf::st_coordinates(d)[, c("X", "Y"), drop = FALSE]
  if (nrow(xy) < 2) return(NULL)
  step <- sqrt(diff(xy[, 1])^2 + diff(xy[, 2])^2)
  data.frame(x = xy[, 1], y = xy[, 2], cum = c(0, cumsum(step)))
}

feature_bearings <- function(g) {
  g <- sf::st_zm(sf::st_geometry(g), drop = TRUE)
  co <- sf::st_coordinates(g)
  fid <- co[, ncol(co)]
  first <- !duplicated(fid); last <- !duplicated(fid, fromLast = TRUE)
  f <- co[first, , drop = FALSE]; l <- co[last, , drop = FALSE]
  bearing180(l[, "X"] - f[, "X"], l[, "Y"] - f[, "Y"])
}

# Default parameter set. Both notebooks build their cfg/params from this (override paths).
gst_default_params <- function(overrides = list()) {
  p <- list(
    crs_work = 2926, segmentize_ft = 50, match_buffer_ft = 80, bearing_tol_deg = 35,
    art_min_mph = 30, res_min_mph = 20, cruise_factor = 1.00, accel_a = 1.1, decel_a = 1.5,
    signalized_types = c("CITY","STATE"), signal_match_ft = 150,
    dwell_signal_s = 8, dwell_tsp_conflict_s = 15, through_signal_delay_s = 15,
    tsp_signal_buffer_ft = 100, tsp_cross_min_deg = 45,
    reentry_base_s = 8, reentry_crit_gap_s = 6, peak_lane_fraction = 0.05,
    resid_aadt_floor = 500, reentry_max_s = 30, vol_match_ft = 120,
    osm_default_mph = 25,   # speed for an OSM-fallback edge whose highway class is unmapped
    stop_route_buffer_ft = 250, min_stops_per_route = 2,
    wsdot_match_ft = 300,   # max stop->WSDOT count-point distance (used only when no SDOT corridor is in range)
    streets_geojson   = "data/public/sdot/seattle_streets.geojson",
    signals_gpkg      = "data/public/sdot/traffic_signals.gpkg",
    signals_url       = "https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services/Traffic_Signal_Assemblies_CDL/FeatureServer/0/query",
    alllanes_geojson  = "outputs/streets/street_grid.geojson",
    osm_streetnet_rds = "outputs/streets/osm_streetnet.rds",       # written by StreetSetup.Rmd
    sdot_counts_rds   = "cache/sdot_2022_flow_corridors.rds",     # SDOT 2022 Traffic Flow Counts (cached)
    sdot_counts_url   = "https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services/2022_Arterial_Traffic_Volumes/FeatureServer/3/query",
    wsdot_counts_csv  = "data/public/wsdot/traffic_counts.csv"
  )
  modifyList(p, overrides)
}

# ---- 1. Reference layers -------------------------------------------------------------
# Paged download of an ArcGIS FeatureServer layer as sf (each page goes through a temp
# .geojson file; reading ArcGIS geojson straight from the response text can drop the CRS).
gst_fetch_arcgis <- function(query_url, page = 2000) {
  if (!requireNamespace("httr", quietly = TRUE)) stop("package 'httr' is needed to download ", query_url)
  out <- list(); offset <- 0
  repeat {
    r <- httr::GET(query_url, query = list(where = "1=1", outFields = "*", outSR = 4326, f = "geojson",
                                           resultOffset = offset, resultRecordCount = page),
                   httr::timeout(180))
    httr::stop_for_status(r)
    tf <- tempfile(fileext = ".geojson")
    writeBin(httr::content(r, as = "raw"), tf)
    pg <- tryCatch(sf::st_read(tf, quiet = TRUE), error = function(e) NULL)
    unlink(tf)
    if (is.null(pg) || nrow(pg) == 0) break
    out[[length(out) + 1]] <- pg
    if (nrow(pg) < page) break
    offset <- offset + nrow(pg)
  }
  if (!length(out)) stop("No features returned from ", query_url)
  cols <- Reduce(intersect, lapply(out, names))
  do.call(rbind, lapply(out, function(x) x[, cols]))
}

gst_load_refs <- function(p) {
  # -- Seattle Streets centerlines (posted speed + arterial class) --
  s0 <- sf::st_read(p$streets_geojson, quiet = TRUE) |> sf::st_zm(drop = TRUE)
  streets <- sf::st_sf(
    seg_compkey = suppressWarnings(as.integer(s0$COMPKEY)),
    seg_segkey  = suppressWarnings(as.integer(s0$COMPKEY)),   # segment id carried on QA diagnostics
    seg_speed   = suppressWarnings(as.numeric(s0$SPEEDLIMIT)),
    seg_art     = as.character(s0$ARTCLASS),
    geometry    = sf::st_geometry(s0))
  streets <- sf::st_transform(streets, p$crs_work)
  streets$seg_bearing <- feature_bearings(streets)

  al0 <- sf::st_read(p$alllanes_geojson, quiet = TRUE) |> sf::st_drop_geometry()
  al  <- data.frame(
    seg_compkey = suppressWarnings(as.integer(al0$COMPKEY)),
    al_segdir   = toupper(trimws(as.character(al0$SEGDIR))),
    new_same    = suppressWarnings(as.integer(al0$NEW_SAMELANECOUNT)),
    new_ops     = suppressWarnings(as.integer(al0$NEW_OPSLANECOUNT)),
    has_bl      = as.character(al0$has_proposed_bus_lane) %in% c("TRUE","true","True","1"))
  al <- al[!is.na(al$seg_compkey) & !duplicated(al$seg_compkey), ]
  streets <- dplyr::left_join(streets, al, by = "seg_compkey")

  # -- SDOT traffic signals (downloaded once, then cached) --
  if (!file.exists(p$signals_gpkg)) {
    message("Downloading SDOT traffic signals -> ", p$signals_gpkg)
    sig_dl <- gst_fetch_arcgis(p$signals_url)
    dir.create(dirname(p$signals_gpkg), recursive = TRUE, showWarnings = FALSE)
    sf::st_write(sig_dl, p$signals_gpkg, quiet = TRUE)
  }
  signals <- sf::st_read(p$signals_gpkg, quiet = TRUE) |> sf::st_zm(drop = TRUE)
  signals <- suppressWarnings(sf::st_cast(signals, "POINT")) |> sf::st_transform(p$crs_work)
  full_signals <- signals[signals$INT_SIGNAL_TYPE_CD %in% p$signalized_types, ]

  # -- OSM road classes (Washington extract), for alignment pieces not on a city street --
  if (!file.exists(p$osm_streetnet_rds))
    stop("OSM street network cache not found: ", p$osm_streetnet_rds, " - run StreetSetup.Rmd first.")
  osm <- readRDS(p$osm_streetnet_rds)
  osm <- osm[!is.na(osm$highway) & osm$highway %in% names(OSM_HW_SPEED) &
               !osm$highway %in% c("service", "track"), "highway"]
  bb  <- sf::st_as_sfc(sf::st_bbox(sf::st_transform(streets, sf::st_crs(osm))))
  osm <- osm[lengths(sf::st_intersects(osm, bb)) > 0, ]
  osm_roads <- sf::st_transform(sf::st_zm(osm, drop = TRUE), p$crs_work)
  osm_roads$osm_speed <- unname(OSM_HW_SPEED[as.character(osm_roads$highway)])
  osm_roads$osm_speed[is.na(osm_roads$osm_speed)] <- p$osm_default_mph

  # -- Public traffic counts: SDOT 2022 Traffic Flow Counts (corridor lines) + WSDOT (points) --
  if (!file.exists(p$sdot_counts_rds)) {
    message("Downloading SDOT 2022 Traffic Flow Counts -> ", p$sdot_counts_rds)
    cor_dl <- gst_fetch_arcgis(p$sdot_counts_url)
    dir.create(dirname(p$sdot_counts_rds), recursive = TRUE, showWarnings = FALSE)
    saveRDS(cor_dl, p$sdot_counts_rds)
  }
  # `aadt` is a ONE-DIRECTION daily volume (what a re-entering bus has to merge into): a count
  # reported for a single direction (DIR_FLOW = N, SB, ...) is used as is, a two-way total
  # (DIR_FLOW blank or TOTAL) is halved.
  cor <- readRDS(p$sdot_counts_rds)
  adt <- suppressWarnings(as.numeric(cor$ADT)); awdt <- suppressWarnings(as.numeric(cor$AWDT))
  vol <- ifelse(is.na(adt) | adt <= 0, awdt, adt)
  dirflow <- toupper(trimws(as.character(cor$DIR_FLOW)))
  two_way <- is.na(dirflow) | dirflow %in% c("", "TOTAL")
  sdot_counts <- sf::st_sf(aadt = ifelse(two_way, vol / 2, vol), geometry = sf::st_geometry(cor))
  sdot_counts <- sdot_counts[!is.na(sdot_counts$aadt) & sdot_counts$aadt > 0, ]
  sdot_counts <- sf::st_transform(sf::st_zm(sdot_counts, drop = TRUE), p$crs_work)

  wsdot_counts <- NULL
  if (!is.null(p$wsdot_counts_csv) && file.exists(p$wsdot_counts_csv)) {
    w <- utils::read.csv(p$wsdot_counts_csv, stringsAsFactors = FALSE, fileEncoding = "UTF-8-BOM")
    w <- w[!is.na(w$X) & !is.na(w$Y) & !is.na(w$AADT) & w$AADT > 0, ]
    both <- !grepl("increasing|decreasing|^[NSEW]", w$DirectionOfTravel, ignore.case = TRUE)
    w$aadt <- ifelse(both, w$AADT / 2, w$AADT)          # one-direction volume, as above
    w <- sf::st_as_sf(w[, c("X", "Y", "aadt")], coords = c("X", "Y"), crs = 3857)
    w <- sf::st_transform(w, p$crs_work)
    wsdot_counts <- w[lengths(sf::st_intersects(w, sf::st_as_sfc(sf::st_bbox(streets)))) > 0, ]
  }

  list(streets = streets, full_signals = full_signals, osm_roads = osm_roads,
       sdot_counts = sdot_counts, wsdot_counts = wsdot_counts)
}

# AADT at a set of points from the public count layers: nearest SDOT 2022 flow-count corridor
# within vol_match_ft; else nearest WSDOT count point within wsdot_match_ft; else NA (the caller
# applies resid_aadt_floor).
gst_point_aadt <- function(pts_sf, refs, p) {
  sc <- refs$sdot_counts
  n1 <- sf::st_nearest_feature(pts_sf, sc)
  d1 <- as.numeric(sf::st_distance(pts_sf, sc[n1, ], by_element = TRUE))
  aadt <- ifelse(d1 <= p$vol_match_ft, sc$aadt[n1], NA_real_)
  wc <- refs$wsdot_counts
  if (!is.null(wc) && nrow(wc) > 0 && anyNA(aadt)) {
    need <- which(is.na(aadt))
    n2 <- sf::st_nearest_feature(pts_sf[need, ], wc)
    d2 <- as.numeric(sf::st_distance(pts_sf[need, ], wc[n2, ], by_element = TRUE))
    aadt[need] <- ifelse(d2 <= p$wsdot_match_ft, wc$aadt[n2], NA_real_)
  }
  aadt
}

# ---- 2. Global prep: sub-segments (speed + merge gate) + TSP-conflict signals ---------
gst_prep <- function(routes_sf, refs, p) {
  routes_sf <- sf::st_transform(routes_sf, p$crs_work)
  streets <- refs$streets; full_signals <- refs$full_signals; osm_roads <- refs$osm_roads
  build_ss <- function(i) {
    ln <- to_single_line(routes_sf[i, ]); cc <- densify_coords(ln, p$segmentize_ft)
    if (is.null(cc)) return(NULL); n <- nrow(cc) - 1
    data.frame(rid = routes_sf$rid[i],
               mx = (cc$x[-1] + cc$x[-(n+1)])/2, my = (cc$y[-1] + cc$y[-(n+1)])/2,
               len_ft = sqrt(diff(cc$x)^2 + diff(cc$y)^2), mid_cum = (cc$cum[-1] + cc$cum[-(n+1)])/2,
               brg = bearing180(diff(cc$x), diff(cc$y)), dir_brg = compass_bearing(diff(cc$x), diff(cc$y)))
  }
  sub <- do.call(rbind, lapply(seq_len(nrow(routes_sf)), build_ss))
  sub_sf <- sf::st_as_sf(sub, coords = c("mx","my"), crs = p$crs_work, remove = FALSE)

  near  <- sf::st_nearest_feature(sub_sf, streets)
  ndist <- as.numeric(sf::st_distance(sub_sf, streets[near, ], by_element = TRUE))
  bdiff <- bearing_diff(sub$brg, streets$seg_bearing[near])
  ok <- ndist <= p$match_buffer_ft & bdiff <= p$bearing_tol_deg
  bad <- which(!ok)
  if (length(bad)) {
    cand <- sf::st_is_within_distance(sub_sf[bad, ], streets, dist = p$match_buffer_ft)
    for (j in seq_along(bad)) {
      ci <- cand[[j]]; if (!length(ci)) next
      bd <- bearing_diff(sub$brg[bad[j]], streets$seg_bearing[ci])
      keep <- ci[bd <= p$bearing_tol_deg]; if (!length(keep)) next
      dd <- as.numeric(sf::st_distance(sub_sf[bad[j], ], streets[keep, ]))
      near[bad[j]] <- keep[which.min(dd)]; ndist[bad[j]] <- min(dd); ok[bad[j]] <- TRUE
    }
  }
  seg_spd <- streets$seg_speed[near]; seg_art <- streets$seg_art[near]
  is_art <- ok & !is.na(seg_art) & seg_art %in% c("1","2","3")
  class_min <- ifelse(is_art, p$art_min_mph, p$res_min_mph)
  posted <- ifelse(ok, seg_spd, NA_real_) * p$cruise_factor
  sub$speed_mph  <- pmax(posted, class_min, na.rm = TRUE)
  sub$seg_segkey <- ifelse(ok, streets$seg_segkey[near], NA)
  sub$arterial   <- is_art; sub$matched <- ok

  # OSM network fallback: sub-segs with no Seattle_Streets match (freeways, ramps, state highways)
  # get the real OSM class speed, NOT the residential floor. osm_roads = the OSM Washington extract.
  sub$osm_fallback <- FALSE
  um <- !ok
  if (any(um)) {
    on_ <- sf::st_nearest_feature(sub_sf[um, ], osm_roads)
    sub$speed_mph[um]    <- pmax(osm_roads$osm_speed[on_], p$res_min_mph, na.rm = TRUE)
    sub$osm_fallback[um] <- TRUE
  }

  seg_segdir <- toupper(trimws(streets$al_segdir[near])); segb <- unname(SEGDIR_BRG[seg_segdir])
  same_d0 <- ang_diff360(sub$dir_brg, segb) <= 90
  ns_ <- streets$new_same[near]; no_ <- streets$new_ops[near]
  gp_d0 <- ifelse(is.na(same_d0), pmax(ns_, no_, na.rm = TRUE), ifelse(same_d0, ns_, no_))
  gp_d1 <- ifelse(is.na(same_d0), pmax(ns_, no_, na.rm = TRUE), ifelse(same_d0, no_, ns_))
  has_bl <- ok & dplyr::coalesce(streets$has_bl[near], FALSE)
  sub$merge_d0 <- has_bl & dplyr::coalesce(gp_d0, 0L) >= 1L
  sub$merge_d1 <- has_bl & dplyr::coalesce(gp_d1, 0L) >= 1L
  sub_sf$merge_d0 <- sub$merge_d0; sub_sf$merge_d1 <- sub$merge_d1
  sub_sf$seg_segkey <- sub$seg_segkey; sub_sf$speed_mph <- sub$speed_mph
  sub_sf$matched <- sub$matched; sub_sf$arterial <- sub$arterial; sub_sf$osm_fallback <- sub$osm_fallback

  nb <- sf::st_is_within_distance(full_signals, sub_sf, dist = p$tsp_signal_buffer_ft)
  tsp <- vapply(nb, function(idx) {
    if (length(idx) < 2) return(FALSE)
    ag <- tapply(sub$brg[idx], sub$rid[idx], stats::median); if (length(ag) < 2) return(FALSE)
    cb <- utils::combn(as.numeric(ag), 2); any(bearing_diff(cb[1, ], cb[2, ]) >= p$tsp_cross_min_deg)
  }, logical(1))
  full_signals$tsp_conflict <- tsp
  conf <- do.call(rbind, lapply(which(tsp), function(s) {
    idx <- nb[[s]]; if (!length(idx)) return(NULL)
    m <- tapply(sub$mid_cum[idx], sub$rid[idx], mean); data.frame(rid = names(m), measure = as.numeric(m))
  }))
  if (is.null(conf)) conf <- data.frame(rid = character(0), measure = numeric(0))

  list(sub = sub, sub_sf = sub_sf, full_signals = full_signals, conf_on_route = conf)
}

# ---- 3. Classify stops ---------------------------------------------------------------
gst_classify_stops <- function(stops_sf, prepped, refs, p) {
  stops_sf <- sf::st_transform(stops_sf, p$crs_work)
  fs <- prepped$full_signals; sub <- prepped$sub; sub_sf <- prepped$sub_sf
  sn   <- sf::st_nearest_feature(stops_sf, fs)
  sdst <- as.numeric(sf::st_distance(stops_sf, fs[sn, ], by_element = TRUE))
  stops_sf$signalized   <- sdst <= p$signal_match_ft
  stops_sf$tsp_conflict <- stops_sf$signalized & fs$tsp_conflict[sn]
  stop_aadt <- gst_point_aadt(stops_sf, refs, p)   # SDOT / WSDOT public counts
  q  <- pmax(stop_aadt, p$resid_aadt_floor, na.rm = TRUE) * p$peak_lane_fraction / 3600
  tc <- p$reentry_crit_gap_s
  stops_sf$aadt <- stop_aadt
  stops_sf$d_re <- round(pmin((1/q) * (exp(q*tc) - 1 - q*tc), p$reentry_max_s), 1)
  snear <- sf::st_nearest_feature(stops_sf, sub_sf)
  stops_sf$merge_d0 <- dplyr::coalesce(sub$merge_d0[snear], FALSE)
  stops_sf$merge_d1 <- dplyr::coalesce(sub$merge_d1[snear], FALSE)
  stops_sf
}

# ---- 4. Per-route stop_times ---------------------------------------------------------
# cand_stops: sf POINTs for THIS route's candidate stops, carrying stop_id + the columns
# gst_classify_stops adds. Caller decides which stops belong to the route (proximity for grid,
# ILP assignment for node); the within-buffer filter just drops anything off the alignment.
gst_route_stop_times <- function(rid, route_geom, cand_stops, prepped, p) {
  ln <- sf::st_transform(to_single_line(route_geom), p$crs_work)   # match crs_work (no-op if already)
  ss <- prepped$sub[prepped$sub$rid == rid, ]
  if (!nrow(ss)) return(NULL)
  cand <- sf::st_transform(cand_stops, p$crs_work)
  within <- lengths(sf::st_is_within_distance(cand, ln, dist = p$stop_route_buffer_ft)) > 0
  cand <- cand[within, ]
  if (nrow(cand) < p$min_stops_per_route) return(NULL)
  cc <- densify_coords(ln, p$segmentize_ft)
  vpts <- sf::st_sfc(lapply(seq_len(nrow(cc)), function(k) sf::st_point(c(cc$x[k], cc$y[k]))), crs = p$crs_work)
  vid  <- sf::st_nearest_feature(cand, sf::st_sf(cum = cc$cum, geometry = vpts))
  cand$measure <- cc$cum[vid]
  cand <- cand[order(cand$measure), ]
  cand <- cand[!duplicated(cand$stop_id), ]
  K <- nrow(cand); if (K < p$min_stops_per_route) return(NULL)

  ss$section <- findInterval(ss$mid_cum, cand$measure)
  leg_time <- numeric(K - 1)
  for (k in seq_len(K - 1)) {
    part <- ss[ss$section == k, ]; seglen <- cand$measure[k+1] - cand$measure[k]
    if (nrow(part) == 0) { cruise <- seglen / (p$res_min_mph * MPH_FTS); v_mph <- p$res_min_mph }
    else { cruise <- sum(part$len_ft / (part$speed_mph * MPH_FTS)); v_mph <- (sum(part$len_ft)/cruise)/MPH_FTS }
    leg_time[k] <- cruise + lost_time(v_mph, p$accel_a, p$decel_a)
  }
  n_thru <- 0L
  for (m in prepped$conf_on_route$measure[prepped$conf_on_route$rid == rid]) {
    if (min(abs(m - cand$measure)) <= p$signal_match_ft) next
    lk <- findInterval(m, cand$measure)
    if (lk >= 1 && lk <= (K - 1)) { leg_time[lk] <- leg_time[lk] + p$through_signal_delay_s; n_thru <- n_thru + 1L }
  }
  dwell_vec <- function(df, mcol) ifelse(df$signalized,
      ifelse(df$tsp_conflict, p$dwell_tsp_conflict_s, p$dwell_signal_s),
      p$reentry_base_s + ifelse(df[[mcol]] %in% TRUE, df$d_re, 0))
  make_dir <- function(stops_df, legs, dw, dir_id) {
    arr <- numeric(nrow(stops_df)); dep <- numeric(nrow(stops_df)); dep[1] <- dw[1]
    for (k in 2:nrow(stops_df)) { arr[k] <- dep[k-1] + legs[k-1]; dep[k] <- arr[k] + dw[k] }
    data.frame(trip_id = paste0(rid, "_d", dir_id),
               arrival_time = secs_to_hms(round(arr)), departure_time = secs_to_hms(round(dep)),
               stop_id = stops_df$stop_id, stop_sequence = seq_len(nrow(stops_df)), stringsAsFactors = FALSE)
  }
  dw0 <- dwell_vec(cand, "merge_d0")
  rev <- cand[K:1, ]
  list(st0 = make_dir(cand, leg_time, dw0, 0),
       st1 = make_dir(rev, rev(leg_time), dwell_vec(rev, "merge_d1"), 1),
       cc = cc, stop_ids = unique(cand$stop_id),
       n_stops = K, n_thru = n_thru, n_tsp = sum(cand$tsp_conflict),
       pct_signalized = round(100*mean(cand$signalized), 0),
       n_gated = sum(!cand$signalized & !cand$merge_d0),
       mean_dwell_s = round(mean(dw0), 1),
       span_mi = (max(cand$measure) - min(cand$measure)) / 5280,
       runtime_s = sum(leg_time) + sum(dw0))
}
