# transit-priority-vision-zero

Analysis code for a master's thesis on transit priority, automated-vehicle traffic and
Vision Zero outcomes in Seattle. The pipeline

1. estimates a multinomial-logit mode-choice model from the PSRC Household Travel Survey
   (**Phase 1**), and
2. evaluates **14 configurations** — five transit networks (existing, 3x frequency, Grid,
   Grid + Local, Node-based) crossed with four street scenarios (current, AV-induced
   traffic, full transit priority, priority + AV) — with a coupled mode-choice / road
   equilibrium for five times of day (**Phase 2**), reporting mode share, travel times,
   speeds and VMT, job accessibility, equity correlation and projected fatalities and
   serious injuries.

Everything is R (developed on R 4.5.2, Windows, 16 cores / 110 GB RAM). Routing uses
[r5r](https://ipeagit.github.io/r5r/) (needs Java 21) and
[dodgr](https://urbananalyst.github.io/dodgr/).

## How to run

```
Rscript run_pipeline.R            # every stage, in order; resumes after an interruption
Rscript run_pipeline.R --quick    # stages 1-6, Phase 2 for two scenarios at midday only
Rscript run_pipeline.R --list     # show the stage list
Rscript run_pipeline.R 2 4        # only stages 2..4
```

Run from the repository root, after placing the input data (see "Data"). Each stage is
one notebook, rendered in its own R process; console output goes to `logs/<stage>.log`
and a finished stage leaves `logs/<stage>.done` so it is skipped next time. Every notebook
can also be opened and run interactively in RStudio, with the repository root as the
working directory.

`--quick` checks that the whole pipeline runs without the day-long scenario matrix: Phase 2
solves only the midday period for the baseline and two scenarios — Grid + Local with
transit priority and AV traffic, and the existing network with AV traffic — writing to
`outputs/phase2_quick/`.

Before the first run:

* Install Java 21 for r5r (`rJavaEnv::java_quick_install(21)` is the easy route).
* Put a Census API key in `~/.Renviron` as `CENSUS_API_KEY=...`
  (free: <https://api.census.gov/data/key_signup.html>).
* The two Phase notebooks install missing R packages on demand; the others assume
  `sf dplyr tidyr data.table dodgr r5r osmextract osmdata tigris tidycensus mlogit dfidx
  mgcv duckdb gtfsio zip httr ompr ompr.roi ROI.plugin.highs highs matrixStats` are present.

A full run is long: Phase 2 solves 70 equilibria (14 configurations x 5 times of day)
and took most of a day on the machine above, and the sensitivity stage re-runs part of
Phase 2 nine more times. All heavy steps cache their results under `cache/`, so a re-run
only recomputes what changed.

## Pipeline stages

| # | File | What it does | Main outputs |
|---|------|--------------|--------------|
| 1 | `StreetSetup.Rmd` | The street network every later stage uses: (1) the OpenStreetMap Washington extract clipped to the four PSRC counties, as a routable drive graph with an OSM way id on every edge; (2) the Seattle street grid with every segment's properties — current lane counts per direction, lane counts after the proposed bus lanes, lane widths, arterial / divided / ramp flags; (3) corrections to the SDOT-segment to OSM-way crosswalk on named corridors (freeways, bridges, divided arterials). | `outputs/streets/` |
| 2 | `GenerateGridAndLocal.Rmd` | Turns the hand-drawn Grid and Grid + Local routes and stops into GTFS feeds, with street-derived running times and signal-based dwell. | `outputs/gtfs/gtfs_grid_*.zip` |
| 3 | `GenerateNodeGTFS.Rmd` | The Node-based network: (1) half-mile demand grid from SoundCast trips, the node-count sweep (6-16 nodes) and the p-median selection of 12 nodes; (2) rail corridors from the existing feeds and express-bus corridors selected by integer program; (3) local feeder routes covering the frequent and local stop sets, selected by a travel-time assignment integer program. | `outputs/gtfs/gtfs_node_*.zip`, `outputs/node_design/` |
| 4 | `GTFSTriplication.Rmd` | King County Metro feed variants: 3x frequency, and the existing and 3x networks each with full transit priority and with AV-traffic slowdown (per-route slowdowns from `data/own/kcm_av_route_slowdown.csv`). | `data/gtfs/kcm/kcm_*_april_26.zip` |
| 5 | `Phase1BuildMNL.Rmd` | **Phase 1.** Loads the Household Travel Survey, computes walk / bike / transit / drive skims, calibrates drive times, models parking cost and transit fares, and fits the mode-choice model. | `outputs/phase1/` |
| 6 | `Phase2RunSimulation.Rmd` | **Phase 2.** The mode-choice / road-equilibrium loop for the 14 configurations and five times of day, and every result table. | `outputs/phase2/` |
| 7 | `SensitivityAnalysis.Rmd` | One-factor-at-a-time sensitivity of the Grid + Local AV scenario to five constants (AM peak). | `outputs/sensitivity/` |
| 8 | `ThesisTables.Rmd` | Every data-driven table in the thesis (2, 8-10, 12, 14-24, 26-29). | `outputs/tables/` |
| 9 | `ThesisFigures.Rmd` | The data behind every data-driven figure: chart data for Office and map layers for ArcGIS Pro. | `outputs/figures/` |

Supporting files:

| File | Purpose |
|------|---------|
| `run_pipeline.R` | Runs the stages above in order (resumable). |
| `BusStopTimeModel.R` | The one bus running-time and dwell model used by stages 2 and 3: posted speed with class floors, acceleration / deceleration loss, signal delay, and a gap-acceptance delay for re-entering traffic (from SDOT and WSDOT traffic counts). |

## Folders

```
data/
  own/       the author's own data, included in the repository
  gtfs/      GTFS feeds: the downloaded feeds, plus the King County Metro variants stage 4 writes to gtfs/kcm/
  public/    every other public input (download yourself; see below)
outputs/     everything the pipeline generates, one folder per stage or topic
cache/       intermediate results and downloads kept between runs (safe to delete)
logs/        one log per stage
```

## Data

### `data/own/` — included in this repository

These are the author's own work and cannot be downloaded elsewhere.

| File | What it is |
|------|------------|
| `sdot_snd_osm_crosswalk.csv` | Crosswalk from SDOT street segments (`COMPKEY`, `SND_ID`, direction) to OpenStreetMap way ids, with match quality and the segment's SDOT street attributes. |
| `osm_snd_corridors.csv` | Corridor name map (OSM name / ref to SDOT street names) that drives the way-id repair in stage 1. |
| `proposed_bus_lanes.geojson` | Proposed bus-lane segments, as an overlay on Seattle Streets. |
| `gateway_points.geojson` | Cordon gateway points where major roads cross the city boundary; trips with an end outside Seattle are loaded at these points. |
| `grid_network.gpkg` | Hand-drawn routes and stops for the Grid and Grid + Local networks (express, frequent and local layers). |
| `node_stops/` | Node-based network inputs (shapefiles): `corridor_stops` (hand-placed node locations), `transfer_points`, and the `frequent_stops` and `local_stops` sets the feeder routes must cover. |
| `kcm_av_route_slowdown.csv` | Per-route slowdown of the existing King County Metro routes under AV-induced traffic (congested / free-flow travel time along each route). Generated once with a preliminary road-congestion model of AV traffic and kept as a fixed input; stage 4 applies it to build the AV-traffic feeds. |

### `data/gtfs/` — download yourself

All feeds come from Sound Transit's Open Transit Data downloads page:
<https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd/otd-downloads>

| Feed | Path |
|------|------|
| Puget Sound consolidated feed, Spring 2026 (Phase 1 routing) | `data/gtfs/puget_sound_consolidated_spring26.zip` |
| King County Metro, Spring 2026 (the existing network) | `data/gtfs/kcm/kcm_transit_april_26.zip` |
| The other regional operators, Spring 2026 (Sound Transit, Community Transit, Pierce Transit, Kitsap Transit, Intercity Transit, Everett Transit, Washington State Ferries, Seattle Center Monorail); added unchanged to every scenario | `data/gtfs/other_agencies/*.zip` |

### `data/public/` — download yourself

Place these files at the paths shown (rename the downloads to these names).

| Dataset | Path |
|---------|------|
| PSRC Household Travel Survey, 2017-2023 — trips and households tables | `data/public/psrc_hts/hts_trips.csv`, `data/public/psrc_hts/hts_households.csv` |
| PSRC SoundCast / DaySim outputs — trip roster and parcel geography | `data/public/soundcast/_trip.tsv`, `data/public/soundcast/parcel_2023_geography.csv` |
| OpenStreetMap, Washington extract (2026-01-22) | `data/public/osm/washington-260122.osm.pbf` |
| SDOT Traffic Lanes | `data/public/sdot/traffic_lanes.geojson` |
| City of Seattle Traffic Flow Count studies (CSV export) | `data/public/sdot/traffic_flow_counts.csv` |
| WSDOT traffic count data (CSV export) | `data/public/wsdot/traffic_counts.csv` |

### Downloaded automatically by the code

SDOT Seattle Streets and Traffic Signals (saved to `data/public/sdot/` on first use);
the SDOT 2022 Arterial Traffic Volumes layer, SDOT Collisions, SDOT paid-parking rate
tiers, Restricted Parking Zone areas, Blockface, public garages and parking lots,
Neighborhood Map Atlas districts, the Racial and Social Equity Composite Index, LEHD
LODES workplace area characteristics, TIGER/Line 2020 tracts, blocks and places, Census
block population, and ACS commute mode (B08301) (kept in `cache/`).

Phase 1 builds its drive graph from OpenStreetMap tiles cached in `cache/osm_tiles_sc/`.
These were downloaded through the Overpass API during the thesis work and are not
redistributed here; without them Phase 1 builds the graph from the Washington extract
instead, which gives slightly different calibrated drive times and coefficients.

## Outputs

* `outputs/streets/` — `drive_graph.rds` (routable drive graph), `osm_streetnet.rds`
  (driveable OSM ways), `street_grid.geojson` (every Seattle street segment with its
  properties), `way_id_repair.csv` (crosswalk corrections).
* `outputs/gtfs/` — the generated Grid, Grid + Local and Node-based feeds. These are
  tracked in git so the designed networks can be inspected without running anything.
* `outputs/grid_local/`, `outputs/node_design/` — the designed networks' feed tables,
  design tables and shapefiles.
* `outputs/phase1/` — fitted model, coefficient table, values of travel time.
* `outputs/phase2/` — results by configuration and time of day: mode share, travel
  time, VMT and speed, walkshed, employment accessibility, equity correlation, Vision
  Zero, and `arcgis_layers/network_full.gpkg` (per-street flows and speeds).
* `outputs/sensitivity/` — sensitivity renders and the collected metrics.
* `outputs/tables/`, `outputs/figures/` — the thesis tables and figure data.

The King County Metro feed variants are the one generated product outside `outputs/`:
stage 4 writes them next to the downloaded feed in `data/gtfs/kcm/`.

## Data sources

Puget Sound Regional Council (Household Travel Survey; SoundCast / DaySim model outputs);
U.S. Census Bureau (TIGER/Line 2020, American Community Survey, LEHD LODES);
Seattle Department of Transportation and City of Seattle open data (paid parking rate
tiers, Restricted Parking Zone areas, Blockface, Neighborhood Map Atlas districts, Racial
and Social Equity Composite Index, Seattle Streets, Traffic Lanes, Traffic Signals,
Traffic Flow Count, SDOT Collisions, public garages and parking lots); Washington State
Department of Transportation (traffic counts); OpenStreetMap contributors (Washington
extract, ODbL); Sound Transit (Puget Sound consolidated GTFS, Spring 2026).
