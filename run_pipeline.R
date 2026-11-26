# =====================================================================================
# run_pipeline.R - run the analysis, one notebook per stage, in dependency order.
#
#   Rscript run_pipeline.R                 # run every stage that has not finished yet
#   Rscript run_pipeline.R 5 7             # run only stages 5..7
#   Rscript run_pipeline.R --quick         # stages 1-6, with Phase 2 reduced to five check runs
#   Rscript run_pipeline.R --workers 3     # R processes run side by side (default: RAM / 20 GB)
#   Rscript run_pipeline.R --status        # progress of the current run (also kept in logs/STATUS.txt)
#   Rscript run_pipeline.R --list          # print the stage list and exit
#
# Run it from the repository root. Every notebook render is its own R process (clean
# Java VM for r5r). A finished render writes logs/<name>.done and is skipped on the next
# call, so an interrupted run resumes where it stopped; delete the .done file (or the
# whole logs/ folder) to force it to run again. The run stops at the first stage that
# fails; each render's console output is in logs/<name>.log and its progress (current
# chunk, plus the notebook's own progress messages) in logs/<name>.progress.log.
#
# Parallel work (--workers):
#   Phase 2      a primer render caches the shared networks, skims and per-time-of-day
#                flow seeds; then one render per configuration solves its five
#                equilibria into the shared cache, --workers at a time; then a final
#                render assembles every table from the cache.
#   --quick      the primer caches the baseline for all five times of day; then five
#                check runs, each one network at a different time of day (plus the
#                baseline it is compared with), run --workers at a time and write
#                their full results to outputs/phase2_quick/<tod>_<config>/.
#   Sensitivity  the base point first, then the other points --workers at a time.
#
# No HTML reports are produced: every result is written to disk by the notebooks
# themselves (outputs/, plus the King County Metro feed variants in data/gtfs/kcm/).
# =====================================================================================

stages <- c(
  # ---- A. street network + transit networks ----
  "StreetSetup.Rmd",              #  1 drive graph, street grid with lane counts, way-id repair
  "GenerateGridAndLocal.Rmd",     #  2 Grid and Grid + Local feeds
  "GenerateNodeGTFS.Rmd",         #  3 Node-based network feeds
  "GTFSTriplication.Rmd",         #  4 King County Metro feed variants (3x, priority, AV)
  # ---- B. the model ----
  "Phase1BuildMNL.Rmd",           #  5 Phase 1: mode-choice model
  "Phase2RunSimulation.Rmd",      #  6 Phase 2: 14 configurations x 5 times of day
  "SensitivityAnalysis.Rmd",      #  7 one-factor-at-a-time sensitivity (AM peak)
  # ---- C. reporting ----
  "ThesisTables.Rmd",             #  8 thesis tables
  "ThesisFigures.Rmd"             #  9 data behind the thesis figures
)

BASELINE <- "baseline__no_pri_no_av"
CONFIGS <- c(                     # the 14 configurations of Phase 2
  "baseline__no_pri_no_av", "baseline__no_pri_av", "baseline__pri_no_av", "baseline__pri_av",
  "triplicate__no_pri_no_av", "triplicate__no_pri_av", "triplicate__pri_no_av", "triplicate__pri_av",
  "grid__pri_no_av", "grid__pri_av", "grid_local__pri_no_av", "grid_local__pri_av",
  "node__pri_no_av", "node__pri_av")
# --quick: every transit network once, each at a different time of day and street scenario.
QUICK_CELLS <- data.frame(
  tod    = c("AM",                 "Midday",          "PM",                  "Evening",            "Night"),
  config = c("grid_local__pri_av", "node__pri_no_av", "baseline__no_pri_av", "triplicate__pri_av", "grid__pri_no_av"))
WORKER_HEAP_GB <- 16L             # Java heap per parallel Phase 2 render

# ---------------------------------------------------------------- arguments
args  <- commandArgs(trailingOnly = TRUE)
quick <- "--quick" %in% args
if (!file.exists("run_pipeline.R")) stop("Run this script from the repository root.")
dir.create("logs", showWarnings = FALSE)
if ("--list" %in% args) {
  cat(sprintf("%d  %s\n", seq_along(stages), stages), sep = "")
  quit(status = 0)
}
wi <- match("--workers", args)
workers <- if (!is.na(wi)) as.integer(args[wi + 1]) else
  max(1L, as.integer(floor(ps::ps_system_memory()$total / 1024^3 / 20)))
stopifnot(!is.na(workers), workers >= 1)
positional <- args[!grepl("^--", args) & seq_along(args) != (if (is.na(wi)) 0L else wi + 1L)]
nums  <- suppressWarnings(as.integer(positional))
first <- if (length(nums) >= 1) nums[1] else 1L
last  <- if (length(nums) >= 2) nums[2] else if (quick) 6L else length(stages)
stopifnot(!is.na(first), !is.na(last), first >= 1, last <= length(stages), first <= last)

stamp <- function(t = Sys.time()) format(t, "%Y-%m-%d %H:%M:%S")
lf    <- function(name, ext) file.path("logs", paste0(name, ext))

# ---------------------------------------------------------------- jobs
# A job is one notebook render; its name keys its log files. A stage is a list of
# job groups, run one group after another, the jobs within a group in parallel.
job <- function(name, rmd, params = NULL) list(name = name, rmd = rmd, params = params)

stage_jobs <- function(rmd, quick) {
  name <- tools::file_path_sans_ext(rmd)
  if (rmd == "Phase2RunSimulation.Rmd" && quick) {
    primer <- job("Phase2RunSimulation_quick_primer", rmd,
                  list(configs_filter = BASELINE, stop_after = "seeds",
                       output_dir = "./outputs/phase2_quick/primer"))
    cells <- lapply(seq_len(nrow(QUICK_CELLS)), function(i) {
      tag <- paste0(QUICK_CELLS$tod[i], "_", QUICK_CELLS$config[i])
      job(paste0("Phase2RunSimulation_quick_", tag), rmd,
          list(configs_filter = c(BASELINE, QUICK_CELLS$config[i]),
               tods_to_run = QUICK_CELLS$tod[i], java_heap_gb = WORKER_HEAP_GB,
               output_dir = paste0("./outputs/phase2_quick/", tag)))
    })
    return(list(list(primer), cells))
  }
  if (rmd == "Phase2RunSimulation.Rmd") {
    primer <- job("Phase2RunSimulation_primer", rmd,
                  list(stop_after = "seeds", output_dir = "./outputs/phase2_parts/primer"))
    cells <- lapply(CONFIGS, function(cfg)
      job(paste0("Phase2RunSimulation_", cfg), rmd,
          list(configs_filter = cfg, stop_after = "cells", java_heap_gb = WORKER_HEAP_GB,
               output_dir = paste0("./outputs/phase2_parts/", cfg))))
    return(list(list(primer), cells, list(job(name, rmd))))
  }
  if (rmd == "SensitivityAnalysis.Rmd")
    return(list(list(job(name, rmd, list(workers = workers)))))
  list(list(job(name, rmd)))
}

n_chunks <- function(rmd) sum(grepl("^```\\{r", readLines(rmd, warn = FALSE)))

start_job <- function(j) {
  script <- tempfile(fileext = ".R")
  writeLines(c(
    "options(warn = 1)",
    # Every chunk start is logged to the progress file, so --status can say where it is.
    sprintf(".pl_n <- %dL; .pl_k <- 0L", n_chunks(j$rmd)),
    "knitr::opts_hooks$set(pipeline_progress = function(options) {",
    "  .pl_k <<- .pl_k + 1L",
    "  cat(sprintf('[%s] -- chunk %d/%d %s\\n', format(Sys.time(), '%H:%M:%S'), .pl_k, .pl_n,",
    "              options$label), file = Sys.getenv('PIPELINE_LOG'), append = TRUE)",
    "  options })",
    "knitr::opts_chunk$set(pipeline_progress = TRUE)",
    sprintf("prm <- %s", paste(deparse(j$params), collapse = " ")),
    # Render a private copy so parallel renders of one notebook keep separate knitr
    # scratch files; the repository stays the working directory.
    sprintf("rmd <- file.path(tempdir(), %s); file.copy(%s, rmd)", deparse(j$rmd), deparse(j$rmd)),
    "rmarkdown::render(rmd, output_format = 'html_document', run_pandoc = FALSE, knit_root_dir = getwd(),",
    "                  params = prm, quiet = FALSE, envir = new.env())"), script)
  for (ext in c(".done", ".failed")) unlink(lf(j$name, ext))
  writeLines(stamp(), lf(j$name, ".started"))
  writeLines("", lf(j$name, ".progress.log"))
  rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  processx::process$new(rscript, script, stdout = lf(j$name, ".log"), stderr = "2>&1",
    env = c("current", PIPELINE_LOG = normalizePath(lf(j$name, ".progress.log"), winslash = "/")))
}

# Runs jobs `n` at a time; returns the names of the ones that failed. After a
# failure, jobs already running finish but no new ones start.
run_jobs <- function(jobs, n) {
  done  <- vapply(jobs, function(j) file.exists(lf(j$name, ".done")), logical(1))
  for (j in jobs[done]) cat(sprintf("[%s]   %s already done - skipping\n", stamp(), j$name))
  queue <- jobs[!done]
  running <- list(); failed <- character()
  while (length(queue) || length(running)) {
    for (nm in names(running)) {
      p <- running[[nm]]
      if (p$is_alive()) next
      mins <- as.numeric(difftime(Sys.time(), p$get_start_time(), units = "mins"))
      if (identical(p$get_exit_status(), 0L)) {
        writeLines(sprintf("finished %s (%.1f min)", stamp(), mins), lf(nm, ".done"))
        cat(sprintf("[%s]   %s finished in %.1f min\n", stamp(), nm, mins))
      } else {
        writeLines(sprintf("failed %s (%.1f min)", stamp(), mins), lf(nm, ".failed"))
        cat(sprintf("[%s]   %s FAILED after %.1f min - see logs/%s.log\n", stamp(), nm, mins, nm))
        failed <- c(failed, nm)
      }
      running[[nm]] <- NULL
    }
    if (length(failed)) queue <- list()
    while (length(running) < n && length(queue)) {
      j <- queue[[1]]; queue <- queue[-1]
      cat(sprintf("[%s]   %s starting\n", stamp(), j$name))
      running[[j$name]] <- start_job(j)
    }
    writeLines(status_text(), lf("STATUS", ".txt"))
    if (length(running)) Sys.sleep(15)
  }
  failed
}

# ---------------------------------------------------------------- status
last_lines <- function(f, n = 1, pattern = NULL, invert = FALSE) {
  if (!file.exists(f)) return(character())
  x <- tryCatch(readLines(f, warn = FALSE), error = function(e) character())
  x <- trimws(x[grepl("[[:alnum:]]", x)])   # drop blank and "=====" rule lines
  if (!is.null(pattern)) x <- x[xor(grepl(pattern, x, fixed = TRUE), invert)]
  tail(x, n)
}
job_state <- function(name) {
  if (file.exists(lf(name, ".done")))   return(paste("done     ", readLines(lf(name, ".done"))[1]))
  if (file.exists(lf(name, ".failed"))) return(paste("FAILED   ", readLines(lf(name, ".failed"))[1]))
  if (!file.exists(lf(name, ".started"))) return("pending")
  st <- as.POSIXct(readLines(lf(name, ".started"))[1])
  idle <- as.numeric(difftime(Sys.time(), file.info(lf(name, ".progress.log"))$mtime, units = "mins"))
  sprintf("running  since %s (%.0f min), last progress %.0f min ago",
          format(st, "%H:%M"), as.numeric(difftime(Sys.time(), st, units = "mins")), idle)
}
job_detail <- function(name, indent) {
  pl  <- lf(name, ".progress.log")
  out <- c(last_lines(pl, 1, " -- chunk "), last_lines(pl, 2, " -- chunk ", invert = TRUE))
  if (length(out)) paste0(indent, "| ", substr(out, 1, 150)) else character()
}
status_text <- function() {
  mode <- if (file.exists(lf("run_mode", ".txt"))) readLines(lf("run_mode", ".txt"))[1] else "no run recorded"
  q    <- startsWith(mode, "quick")
  rng  <- regmatches(mode, regexec("stages ([0-9]+)-([0-9]+)", mode))[[1]]
  in_run <- if (length(rng) == 3) seq(as.integer(rng[2]), as.integer(rng[3])) else seq_along(stages)
  out  <- c(sprintf("Pipeline status at %s", stamp()), sprintf("Run: %s", mode), "")
  started <- function(jobs) any(file.exists(lf(vapply(jobs, `[[`, "", "name"), ".started")))
  for (i in seq_along(stages)) {
    jobs   <- unlist(stage_jobs(stages[i], q), recursive = FALSE)
    other  <- unlist(stage_jobs(stages[i], !q), recursive = FALSE)
    if (!started(jobs) && started(other)) jobs <- other   # e.g. a --quick Phase 2 before a later run

    names  <- vapply(jobs, `[[`, "", "name")
    states <- vapply(names, job_state, "")
    overall <- if (all(startsWith(states, "done"))) "done" else
      if (any(startsWith(states, "FAILED"))) "FAILED" else
      if (any(!startsWith(states, "pending"))) "running" else "pending"
    if (overall == "pending" && !i %in% in_run) overall <- states[] <- "not in this run"
    single <- length(names) == 1
    out <- c(out, sprintf("%d  %-26s %s", i, stages[i], if (single) states[1] else overall))
    for (k in seq_along(names)) {
      if (!single && overall != "pending")
        out <- c(out, sprintf("     %-50s %s", sub("^Phase2RunSimulation_", "", names[k]), states[k]))
      if (!startsWith(states[k], "done") && !startsWith(states[k], "pending"))
        out <- c(out, job_detail(names[k], "        "))
    }
    if (stages[i] == "SensitivityAnalysis.Rmd" && overall != "done") {
      pts <- sub("^sensitivity_(.*)\\.progress\\.log$", "\\1",
                 list.files("logs", "^sensitivity_.*\\.progress\\.log$"))
      for (p in pts) {
        ok <- file.exists(file.path("outputs/sensitivity", p, "mode_share_by_config_tod.csv"))
        out <- c(out, sprintf("       point %-44s %s", p, if (ok) "done" else "running or not finished"))
        if (!ok) out <- c(out, job_detail(paste0("sensitivity_", p), "          "))
      }
    }
  }
  c(out, "", "Lines starting '| ' are the latest entries of that render's logs/<name>.progress.log.")
}

if ("--status" %in% args) {
  cat(status_text(), sep = "\n")
  quit(status = 0)
}

# ---------------------------------------------------------------- run
writeLines(sprintf("%s, stages %d-%d, %d worker(s), started %s",
                   if (quick) "quick check" else "full run", first, last, workers, stamp()),
           lf("run_mode", ".txt"))
cat(sprintf("[%s] stages %d-%d, %d worker(s)%s\n", stamp(), first, last, workers,
            if (quick) ", quick check" else ""))
for (i in first:last) {
  cat(sprintf("[%s] stage %d %s\n", stamp(), i, stages[i]))
  for (group in stage_jobs(stages[i], quick)) {
    failed <- run_jobs(group, workers)
    if (length(failed)) {
      cat(sprintf("[%s] stopped: stage %d failed (%s)\n", stamp(), i, paste(failed, collapse = ", ")))
      quit(status = 1)
    }
  }
}
writeLines(status_text(), lf("STATUS", ".txt"))
cat(sprintf("[%s] requested stages complete\n", stamp()))
