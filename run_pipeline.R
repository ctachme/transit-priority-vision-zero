# =====================================================================================
# run_pipeline.R - run the analysis, one notebook per stage, in dependency order.
#
#   Rscript run_pipeline.R                 # run every stage that has not finished yet
#   Rscript run_pipeline.R 2 4             # run only stages 2..4
#   Rscript run_pipeline.R --quick         # stages 1-6, but Phase 2 solves two scenarios (+ baseline)
#                                          # at midday only (a check that everything runs)
#   Rscript run_pipeline.R --list          # print the stage list and exit
#
# Run it from the repository root. Each stage is rendered in its own R process (clean
# Java VM for r5r). A stage that finishes writes logs/<stage>.done and is skipped on the
# next call, so an interrupted run resumes where it stopped; delete the .done file (or
# the whole logs/ folder) to force a stage to run again. The run stops at the first
# stage that fails; its console output is in logs/<stage>.log.
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

# --quick: two scenarios plus the baseline they are compared with, midday only.
quick_params <- list(
  "Phase2RunSimulation.Rmd" = list(
    tods_to_run    = "Midday",
    configs_filter = c("baseline__no_pri_no_av", "baseline__no_pri_av", "grid_local__pri_av"),
    output_dir     = "./outputs/phase2_quick")
)

args  <- commandArgs(trailingOnly = TRUE)
quick <- "--quick" %in% args
if ("--list" %in% args) {
  cat(sprintf("%2d  %s\n", seq_along(stages), stages), sep = "")
  quit(status = 0)
}
nums  <- suppressWarnings(as.integer(args[!grepl("^--", args)]))
first <- if (length(nums) >= 1) nums[1] else 1L
last  <- if (length(nums) >= 2) nums[2] else if (quick) 6L else length(stages)
stopifnot(!is.na(first), !is.na(last), first >= 1, last <= length(stages), first <= last)

if (!file.exists("run_pipeline.R")) stop("Run this script from the repository root.")
dir.create("logs", showWarnings = FALSE)
rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
stamp   <- function() format(Sys.time(), "%Y-%m-%d %H:%M:%S")

for (i in first:last) {
  rmd  <- stages[i]
  name <- tools::file_path_sans_ext(rmd)
  prm  <- if (quick) quick_params[[rmd]] else NULL
  tag  <- if (is.null(prm)) name else paste0(name, "_quick")
  done <- file.path("logs", paste0(tag, ".done"))
  logf <- file.path("logs", paste0(tag, ".log"))
  if (file.exists(done)) {
    cat(sprintf("[%s] stage %d %-26s already done - skipping\n", stamp(), i, rmd))
    next
  }
  cat(sprintf("[%s] stage %d %-26s starting (log: %s)\n", stamp(), i, rmd, logf))
  script <- tempfile(fileext = ".R")
  writeLines(c(
    "options(warn = 1)",
    sprintf("prm <- %s", paste(deparse(prm), collapse = " ")),
    sprintf("rmarkdown::render(%s, output_format = 'html_document', run_pandoc = FALSE,", deparse(rmd)),
    "                  params = prm, quiet = FALSE, envir = new.env())"), script)
  t0 <- Sys.time()
  status <- system2(rscript, shQuote(script), stdout = logf, stderr = logf)
  mins <- as.numeric(difftime(Sys.time(), t0, units = "mins"))
  # knitr leaves its intermediate markdown and figure folder behind; they are not results.
  unlink(paste0(name, ".knit.md"))
  unlink(paste0(name, "_files"), recursive = TRUE)
  if (!identical(status, 0L)) {
    cat(sprintf("[%s] stage %d %-26s FAILED after %.1f min - see %s\n", stamp(), i, rmd, mins, logf))
    quit(status = 1)
  }
  writeLines(sprintf("finished %s (%.1f min)", stamp(), mins), done)
  cat(sprintf("[%s] stage %d %-26s finished in %.1f min\n", stamp(), i, rmd, mins))
}
cat(sprintf("[%s] requested stages complete\n", stamp()))
