#' Read CmdStan CSV files into R
#'
#' @description `read_cmdstan_csv()` is used internally by CmdStanR to read
#'   CmdStan's output CSV files into \R. It can
#'   also be used by CmdStan users as a more flexible and efficient alternative
#'   to `rstan::read_stan_csv()`. See the **Value** section for details on the
#'   structure of the returned list.
#'
#'   It is also possible to create CmdStanR's fitted model objects directly from
#'   CmdStan CSV files using the `as_cmdstan_fit()` function.
#'
#' @export
#' @param files A character vector of paths to the CmdStan CSV files. These can
#'   be files generated by running CmdStanR or running CmdStan directly.
#' @param variables Optionally, a character vector naming the variables
#'   (parameters, transformed parameters, and generated quantities) to read in.
#'   * If `NULL` (the default) then all variables are included.
#'   * If an empty string (`variables=""`) then none are included.
#'   * For non-scalar variables all elements or specific elements can be selected:
#'     - `variables = "theta"` selects all elements of `theta`;
#'     - `variables = c("theta[1]", "theta[3]")` selects only the 1st and 3rd elements.
#' @param sampler_diagnostics Works the same way as `variables` but for sampler
#'   diagnostic variables (e.g., `"treedepth__"`, `"accept_stat__"`, etc.).
#'   Ignored if the model was not fit using MCMC.
#'
#' @return
#'
#' `as_cmdstan_fit()` returns a [CmdStanMCMC], [CmdStanMLE], or
#' [CmdStanVB] object. Some methods typically defined for those objects will not
#' work (e.g. `save_data_file()`) but the important methods like `$summary()`,
#' `$draws()`, `$sampler_diagnostics()` and others will work fine.
#'
#' `read_cmdstan_csv()` returns a named list with the following components:
#'
#' * `metadata`: A list of the meta information from the run that produced the
#' CSV file(s). See **Examples** below.
#'
#' The other components in the returned list depend on the method that produced
#' the CSV file(s).
#'
#' For [sampling][model-method-sample] the returned list also includes the
#' following components:
#'
#' * `time`: Run time information for the individual chains. The returned object
#' is the same as for the [$time()][fit-method-time] method except the total run
#' time can't be inferred from the CSV files (the chains may have been run in
#' parallel) and is therefore `NA`.
#' * `inv_metric`: A list (one element per chain) of inverse mass matrices
#' or their diagonals, depending on the type of metric used.
#' * `step_size`: A list (one element per chain) of the step sizes used.
#' * `warmup_draws`:  If `save_warmup` was `TRUE` when fitting the model then a
#' [`draws_array`][posterior::draws_array] of warmup draws.
#' * `post_warmup_draws`: A [`draws_array`][posterior::draws_array] of
#' post-warmup draws.
#' * `warmup_sampler_diagnostics`:  If `save_warmup` was `TRUE` when fitting the
#' model then a [`draws_array`][posterior::draws_array] of warmup draws of the
#' sampler diagnostic variables.
#' * `post_warmup_sampler_diagnostics`: A [`draws_array`][posterior::draws_array]
#' of post-warmup draws of the sampler diagnostic variables.
#'
#' For [optimization][model-method-optimize] the returned list also includes the
#' following components:
#'
#' * `point_estimates`: Point estimates for the model parameters.
#'
#' For [variational inference][model-method-variational] the returned list also
#' includes the following components:
#'
#' * `draws`: A [`draws_matrix`][posterior::draws_matrix] of draws from the
#' approximate posterior distribution.
#'
#' For [standalone generated quantities][model-method-generate-quantities] the
#' returned list also includes the following components:
#'
#' * `generated_quantities`: A [`draws_array`][posterior::draws_array] of
#' the generated quantities.
#'
#' @examples
#' \dontrun{
#' # Generate some CSV files to use for demonstration
#' fit1 <- cmdstanr_example("logistic", method = "sample", save_warmup = TRUE)
#' csv_files <- fit1$output_files()
#' print(csv_files)
#'
#' # Creating fitting model objects
#'
#' # Create a CmdStanMCMC object from the CSV files
#' fit2 <- as_cmdstan_mcmc(csv_files)
#' fit2$print("beta")
#'
#' # Using read_cmdstan_csv
#' #
#' # Read in everything
#' x <- read_cmdstan_csv(csv_files)
#' str(x)
#'
#' # Don't read in any of the sampler diagnostic variables
#' x <- read_cmdstan_csv(csv_files, sampler_diagnostics = "")
#'
#' # Don't read in any of the parameters or generated quantities
#' x <- read_cmdstan_csv(csv_files, variables = "")
#'
#' # Read in only specific parameters and sampler diagnostics
#' x <- read_cmdstan_csv(
#'   csv_files,
#'   variables = c("alpha", "beta[2]"),
#'   sampler_diagnostics = c("n_leapfrog__", "accept_stat__")
#' )
#'
#' # For non-scalar parameters all elements can be selected or only some elements,
#' # e.g. all of the vector "beta" but only one element of the vector "log_lik"
#' x <- read_cmdstan_csv(
#'   csv_files,
#'   variables = c("beta", "log_lik[3]")
#' )
#' }
#'
read_cmdstan_csv <- function(files,
                             variables = NULL,
                             sampler_diagnostics = NULL) {
  checkmate::assert_file_exists(files, access = "r", extension = "csv")
  metadata <- NULL
  warmup_draws <- list()
  post_warmup_draws <- list()
  warmup_sampler_diagnostics_draws <- list()
  post_warmup_sampler_diagnostics_draws <- list()
  generated_quantities <- list()
  variational_draws <- NULL
  point_estimates <- NULL
  inv_metric <- list()
  step_size <- list()
  col_types <- NULL
  col_select <- NULL
  metadata <- NULL
  time <- data.frame()
  not_matching <- c()
  for (output_file in files) {
    if (is.null(metadata)) {
      metadata <- read_csv_metadata(output_file)
      if (!is.null(metadata$inv_metric)) {
        inv_metric[[as.character(metadata$id)]] <- metadata$inv_metric
      }
      if (!is.null(metadata$step_size_adaptation)) {
        step_size[[as.character(metadata$id)]] <- metadata$step_size_adaptation
      }
      if (!is.null(metadata$time)) {
        time <- rbind(time, metadata$time)
      }
    } else {
      csv_file_info <- read_csv_metadata(output_file)
      check <- check_csv_metadata_matches(metadata, csv_file_info)
      if (!is.null(check$error)) {
        stop(check$error, call. = FALSE)
      }
      not_matching <- c(not_matching, check$not_matching)
      metadata$id <- c(metadata$id, csv_file_info$id)
      metadata$seed <- c(metadata$seed, csv_file_info$seed)
      metadata$init <- c(metadata$init, csv_file_info$init)
      metadata$step_size <- c(metadata$step_size, csv_file_info$step_size)
      metadata$step_size_adaptation <- c(metadata$step_size_adaptation, csv_file_info$step_size_adaptation)
      metadata$fitted_params <- c(metadata$fitted_params, csv_file_info$fitted_params)

      if (!is.null(csv_file_info$inv_metric)) {
        inv_metric[[as.character(csv_file_info$id)]] <- csv_file_info$inv_metric
      }
      if (!is.null(csv_file_info$step_size_adaptation)) {
        step_size[[as.character(csv_file_info$id)]] <- csv_file_info$step_size_adaptation
      }
      if (!is.null(csv_file_info$time)) {
        time <- rbind(time, csv_file_info$time)
      }
    }
    if (is.null(col_select)) {
      if (is.null(variables)) { # variables = NULL returns all
        variables <- metadata$model_params
      } else if (!any(nzchar(variables))) { # if variables = "" returns none
        variables <- NULL
      } else { # filter using variables
        res <- matching_variables(variables, repair_variable_names(metadata$model_params))
        if (length(res$not_found)) {
          stop("Can't find the following variable(s) in the output: ",
               paste(res$not_found, collapse = ", "), call. = FALSE)
        }
        variables <- unrepair_variable_names(res$matching)
      }
      if (is.null(sampler_diagnostics)) {
        sampler_diagnostics <- metadata$sampler_diagnostics
      } else if (!any(nzchar(sampler_diagnostics))) { # if sampler_diagnostics = "" returns none
        sampler_diagnostics <- NULL
      } else {
        selected_sampler_diag <- rep(FALSE, length(metadata$sampler_diagnostics))
        not_found <- NULL
        for (p in sampler_diagnostics) {
          matches <- metadata$sampler_diagnostics == p | startsWith(metadata$sampler_diagnostics, paste0(p,"."))
          if (!any(matches)) {
            not_found <- c(not_found, p)
          }
          selected_sampler_diag <- selected_sampler_diag | matches
        }
        if (length(not_found)) {
          stop("Can't find the following sampler diagnostic(s) in the output: ",
               paste(not_found, collapse = ", "), call. = FALSE)
        }
        sampler_diagnostics <- metadata$sampler_diagnostics[selected_sampler_diag]
      }
      if (metadata$method == "generate_quantities") {
        col_select <- c(col_select, variables)
      } else {
        col_select <- "lp__"
        col_select <- c(col_select, variables[variables!="lp__"])
        col_select <- c(col_select, sampler_diagnostics)
      }
    }
    if (metadata$method == "sample") {
      num_warmup_draws <- ceiling(metadata$iter_warmup / metadata$thin)
      num_post_warmup_draws <- ceiling(metadata$iter_sampling / metadata$thin)
      all_draws <- num_warmup_draws + num_post_warmup_draws
    } else if (metadata$method == "variational") {
      all_draws <- metadata$output_samples
    } else if (metadata$method == "optimize") {
      all_draws <- 1
    }
    if (length(col_select) > 0) {
      if (os_is_windows()) {
        grep_path <- repair_path(Sys.which("grep.exe"))
        fread_cmd <- paste0(grep_path, " -v '^#' --color=never ", output_file)
      } else {
        fread_cmd <- paste0("grep -v '^#' --color=never ", output_file)
      }
      suppressWarnings(
      draws <- data.table::fread(
          cmd = fread_cmd,
          select = col_select,
          data.table = FALSE
        )
      )
    } else {
      draws <- NULL
    }
    if (nrow(draws) > 0) {
      if (metadata$method == "sample") {
        if (metadata$save_warmup == 1) {
          if (length(variables) > 0) {
            warmup_draws[[length(warmup_draws) + 1]] <- draws[1:num_warmup_draws, variables, drop = FALSE]
            if (num_post_warmup_draws > 0) {
              post_warmup_draws[[length(post_warmup_draws) + 1]] <- draws[(num_warmup_draws+1):all_draws, variables, drop = FALSE]
            }
          }
          if (length(sampler_diagnostics) > 0) {
            warmup_sampler_diagnostics_draws[[length(warmup_sampler_diagnostics_draws) + 1]] <- draws[1:num_warmup_draws, sampler_diagnostics, drop = FALSE]
            if (num_post_warmup_draws > 0) {
              post_warmup_sampler_diagnostics_draws[[length(post_warmup_sampler_diagnostics_draws) + 1]] <- draws[(num_warmup_draws+1):all_draws, sampler_diagnostics, drop = FALSE]
            }
          }
        } else {
            warmup_draws <- NULL
            warmup_sampler_diagnostics_draws <- NULL
            if (length(variables) > 0) {
              post_warmup_draws[[length(post_warmup_draws) + 1]] <- draws[, variables, drop = FALSE]
            }
            if (length(sampler_diagnostics) > 0 && all(metadata$algorithm != "fixed_param")) {
              post_warmup_sampler_diagnostics_draws[[length(post_warmup_sampler_diagnostics_draws) + 1]] <- draws[, sampler_diagnostics, drop = FALSE]
            }
        }
      } else if (metadata$method == "variational") {
        # ignore first line as it's just the mean and lp__ as it's always 0
        variational_draws <- posterior::as_draws_matrix(
          draws[-1, colnames(draws) != "lp__", drop=FALSE]
        )
        if ("log_p__" %in% posterior::variables(variational_draws)) {
          variational_draws <- posterior::rename_variables(variational_draws, lp__ = "log_p__")
        }
        if ("log_g__" %in% posterior::variables(variational_draws)) {
          variational_draws <- posterior::rename_variables(variational_draws, lp_approx__ = "log_g__")
        }
      } else if (metadata$method == "optimize") {
        point_estimates <- posterior::as_draws_matrix(draws[1,, drop=FALSE])[, variables]
      } else if (metadata$method == "generate_quantities") {
        generated_quantities[[length(generated_quantities) + 1]] <- draws
      }
    }
  }
  if (length(not_matching) > 0) {
    not_matching_list <- paste(unique(not_matching), collapse = ", ")
    warning("Supplied CSV files do not match in the following arguments: ",
            paste(not_matching_list, collapse = ", "), call. = FALSE)
  }

  metadata$inv_metric <- NULL
  metadata$model_params <- repair_variable_names(metadata$model_params)
  repaired_variables <- repair_variable_names(variables)
  if (metadata$method == "variational") {
    metadata$model_params <- metadata$model_params[metadata$model_params != "lp__"]
    metadata$model_params <- gsub("log_p__", "lp__", metadata$model_params)
    metadata$model_params <- gsub("log_g__", "lp_approx__", metadata$model_params)
    repaired_variables <- repaired_variables[repaired_variables != "lp__"]
    repaired_variables <- gsub("log_p__", "lp__", repaired_variables)
    repaired_variables <- gsub("log_g__", "lp_approx__", repaired_variables)
  }

  model_param_dims <- variable_dims(metadata$model_params)
  metadata$stan_variable_dims <- model_param_dims
  metadata$stan_variables <- names(model_param_dims)

  if (metadata$method == "sample") {
    warmup_draws <- bind_list_of_draws_array(warmup_draws)
    if (!is.null(warmup_draws)) {
      posterior::variables(warmup_draws) <- repaired_variables
    }
    post_warmup_draws <- bind_list_of_draws_array(post_warmup_draws)
    if (!is.null(post_warmup_draws)) {
      posterior::variables(post_warmup_draws) <- repaired_variables
    }
    warmup_sampler_diagnostics_draws <- bind_list_of_draws_array(warmup_sampler_diagnostics_draws)
    post_warmup_sampler_diagnostics_draws <- bind_list_of_draws_array(post_warmup_sampler_diagnostics_draws)
    list(
      metadata = metadata,
      time = list(total = NA_integer_, chains = time),
      inv_metric = inv_metric,
      step_size = step_size,
      warmup_draws = warmup_draws,
      post_warmup_draws = post_warmup_draws,
      warmup_sampler_diagnostics = warmup_sampler_diagnostics_draws,
      post_warmup_sampler_diagnostics = post_warmup_sampler_diagnostics_draws
    )
  } else if (metadata$method == "variational") {
    if (!is.null(variational_draws)) {
      posterior::variables(variational_draws) <- repaired_variables
    }
    list(
      metadata = metadata,
      draws = variational_draws
    )
  } else if (metadata$method == "optimize") {
    if (!is.null(point_estimates)) {
      posterior::variables(point_estimates) <- repaired_variables
    }
    list(
      metadata = metadata,
      point_estimates = point_estimates
    )
  } else if (metadata$method == "generate_quantities") {
    generated_quantities <- bind_list_of_draws_array(generated_quantities)
    if (!is.null(generated_quantities)) {
      posterior::variables(generated_quantities) <- repaired_variables
    }
    list(
      metadata = metadata,
      generated_quantities = generated_quantities
    )
  }
}

#' Read CmdStan CSV files from sampling into \R
#'
#' Deprecated. Use [read_cmdstan_csv()] instead.
#'
#' @export
#' @param files,variables,sampler_diagnostics Deprecated. Use
#'   [read_cmdstan_csv()] instead.
#'
read_sample_csv <- function(files,
                            variables = NULL,
                            sampler_diagnostics = NULL) {
  warning("read_sample_csv() is deprecated. Please use read_cmdstan_csv().")
  read_cmdstan_csv(files, variables, sampler_diagnostics)
}

#' @rdname read_cmdstan_csv
#' @export
#' @param check_diagnostics For models fit using MCMC, should diagnostic checks
#'   be performed after reading in the files? The default is `TRUE` but set to
#'   `FALSE` to avoid checking for problems with divergences and treedepth.
#'
as_cmdstan_fit <- function(files, check_diagnostics = TRUE) {
  csv_contents <- read_cmdstan_csv(files)
  switch(
    csv_contents$metadata$method,
    "sample" = CmdStanMCMC_CSV$new(csv_contents, files, check_diagnostics),
    "optimize" = CmdStanMLE_CSV$new(csv_contents, files),
    "variational" = CmdStanVB_CSV$new(csv_contents, files)
  )
}


# internal ----------------------------------------------------------------

# CmdStanFit_CSV -------------------------------------------------------------
#' Create CmdStanMCMC/MLE/VB-ish objects from `read_cmdstan_csv()` output
#' instead of from a CmdStanRun object
#'
#' The resulting object has fewer methods than a CmdStanMCMC/MLE/VB object
#' because it doesn't have access to a CmdStanRun object.
#'
#' @noRd
#'
CmdStanMCMC_CSV <- R6::R6Class(
  classname = "CmdStanMCMC_CSV",
  inherit = CmdStanMCMC,
  public = list(
    initialize = function(csv_contents, files, check_diagnostics = TRUE) {
      if (check_diagnostics) {
        check_divergences(csv_contents$post_warmup_sampler_diagnostics)
        check_sampler_transitions_treedepth(csv_contents$post_warmup_sampler_diagnostics, csv_contents$metadata)
      }
      private$output_files_ <- files
      private$metadata_ <- csv_contents$metadata
      private$time_ <- csv_contents$time
      private$inv_metric_ <- csv_contents$inv_metric
      private$sampler_diagnostics_ <- csv_contents$post_warmup_sampler_diagnostics
      private$warmup_sampler_diagnostics_ <- csv_contents$warmup_sampler_diagnostics
      private$warmup_draws_ <- csv_contents$warmup_draws
      private$draws_ <- csv_contents$post_warmup_draws
    },
    # override some methods so they work without a CmdStanRun object
    output_files = function(...) {
      private$output_files_
    },
    time = function() {
      private$time_
    },
    num_chains = function() {
      posterior::nchains(self$draws())
    }
  ),
  private = list(
    output_files_ = NULL,
    time_ = NULL
  )
)
CmdStanMLE_CSV <- R6::R6Class(
  classname = "CmdStanMLE_CSV",
  inherit = CmdStanMLE,
  public = list(
    initialize = function(csv_contents, files) {
      private$output_files_ <- files
      private$draws_ <- csv_contents$point_estimates
      private$metadata_ <- csv_contents$metadata
    },
    output_files = function(...) {
      private$output_files_
    }
  ),
  private = list(output_files_ = NULL)
)
CmdStanVB_CSV <- R6::R6Class(
  classname = "CmdStanVB_CSV",
  inherit = CmdStanVB,
  public = list(
    initialize = function(csv_contents, files) {
      private$output_files_ <- files
      private$draws_ <- csv_contents$draws
      private$metadata_ <- csv_contents$metadata
    },
    output_files = function(...) {
      private$output_files_
    }
  ),
  private = list(output_files_ = NULL)
)

# these methods are unavailable because there's no CmdStanRun object
unavailable_methods_CmdStanFit_CSV <- c(
    "cmdstan_diagnose", "cmdstan_summary",
    "save_data_file", "data_file",
    "save_latent_dynamics_files", "latent_dynamics_files",
    "save_output_files",
    "init",
    "output",
    "return_codes",
    "num_procs",
    "save_profile_files", "profile_files", "profiles",
    "time" # available for MCMC not others
  )
error_unavailable_CmdStanFit_CSV <- function(...) {
  stop("This method is not available for objects created using as_cmdstan_fit().",
       call. = FALSE)
}
for (method in unavailable_methods_CmdStanFit_CSV) {
  if (method != "time") {
    CmdStanMCMC_CSV$set("public", name = method, value = error_unavailable_CmdStanFit_CSV)
  }
  CmdStanMLE_CSV$set("public", name = method, value = error_unavailable_CmdStanFit_CSV)
  CmdStanVB_CSV$set("public", name = method, value = error_unavailable_CmdStanFit_CSV)
}


# csv reading internals ---------------------------------------------------

#' Reads the sampling arguments and the diagonal of the
#' inverse mass matrix from the comments in a CSV file.
#'
#' @noRd
#' @param csv_file A CSV file containing results from CmdStan.
#' @return A list containing all CmdStan settings and, for sampling, the inverse
#'   mass matrix (or its diagonal depending on the metric).
#'
read_csv_metadata <- function(csv_file) {
  checkmate::assert_file_exists(csv_file, access = "r", extension = "csv")
  adaptation_terminated <- FALSE
  param_names_read <- FALSE
  inv_metric_next <- FALSE
  inv_metric_diagonal_next <- FALSE
  csv_file_info <- list()
  csv_file_info$inv_metric <- NULL
  inv_metric_rows_to_read <- -1
  inv_metric_rows <- -1
  parsing_done <- FALSE
  dense_inv_metric <- FALSE
  warmup_time <- 0
  sampling_time <-0
  total_time <- 0
  if (os_is_windows()) {
    grep_path <- repair_path(Sys.which("grep.exe"))
    fread_cmd <- paste0(grep_path, " '^[#a-zA-Z]' --color=never ", csv_file)
  } else {
    fread_cmd <- paste0("grep '^[#a-zA-Z]' --color=never ", csv_file)
  }
  suppressWarnings(
    metadata <- data.table::fread(
      cmd = fread_cmd,
      colClasses = "character",
      stringsAsFactors = FALSE,
      fill = TRUE,
      sep = "",
      header= FALSE
    )
  )
  if (is.null(metadata) || length(metadata) == 0) {
    stop("Supplied CSV file is corrupt!", call. = FALSE)
  }
  for (line in metadata[[1]]) {
    if (!startsWith(line, "#") && is.null(csv_file_info[["model_params"]])) {
      # if no # at the start of line, the line is the CSV header
      all_names <- strsplit(line, ",")[[1]]
      if (all(csv_file_info$algorithm != "fixed_param")) {
        csv_file_info[["sampler_diagnostics"]] <- all_names[endsWith(all_names, "__")]
        csv_file_info[["sampler_diagnostics"]] <- csv_file_info[["sampler_diagnostics"]][!(csv_file_info[["sampler_diagnostics"]] %in% c("lp__", "log_p__", "log_g__"))]
        csv_file_info[["model_params"]] <- all_names[!(all_names %in% csv_file_info[["sampler_diagnostics"]])]
      } else {
        csv_file_info[["model_params"]] <- all_names[!endsWith(all_names, "__")]
      }
    } else {
      parse_key_val <- TRUE
      if (grepl("# Diagonal elements of inverse mass matrix:", line, perl = TRUE)) {
        inv_metric_next <- TRUE
        parse_key_val <- FALSE
        inv_metric_rows <- 1
        inv_metric_rows_to_read <- 1
        dense_inv_metric <- FALSE
      } else if (grepl("# Elements of inverse mass matrix:", line, perl = TRUE)) {
        inv_metric_next <- TRUE
        parse_key_val <- FALSE
        dense_inv_metric <- TRUE
      } else if (inv_metric_next) {
        inv_metric_split <- strsplit(gsub("# ", "", line), ",")
        numeric_inv_metric_split <- rapply(inv_metric_split, as.numeric)
        if (inv_metric_rows == -1 && dense_inv_metric) {
          inv_metric_rows <- length(inv_metric_split[[1]])
          inv_metric_rows_to_read <- inv_metric_rows
        }
        csv_file_info$inv_metric <- c(csv_file_info$inv_metric, numeric_inv_metric_split)
        inv_metric_rows_to_read <- inv_metric_rows_to_read - 1
        if (inv_metric_rows_to_read == 0) {
          inv_metric_next <- FALSE
        }
        parse_key_val <- FALSE
      }
      if (parse_key_val) {
        tmp <- gsub("#", "", line, fixed = TRUE)
        tmp <- gsub("(Default)", "", tmp, fixed = TRUE)
        key_val <- grep("=", tmp, fixed = TRUE, value = TRUE)
        key_val <- strsplit(key_val, split = "=", fixed = TRUE)
        key_val <- rapply(key_val, trimws)
        if (any(key_val[1] == "Step size")) {
          key_val[1] <- "step_size_adaptation"
        }
        if (length(key_val) == 2) {
          numeric_val <- suppressWarnings(as.numeric(key_val[2]))
          if (!is.na(numeric_val)) {
            csv_file_info[[key_val[1]]] <- numeric_val
          } else {
            if (nzchar(key_val[2])) {
              csv_file_info[[key_val[1]]] <- key_val[2]
            }
          }
        } else if (grepl("(Warm-up)", tmp, fixed = TRUE)) {
          tmp <- gsub("Elapsed Time:", "", tmp, fixed = TRUE)
          tmp <- gsub("seconds (Warm-up)", "", tmp, fixed = TRUE)
          warmup_time <- as.numeric(tmp)
        } else if (grepl("(Sampling)", tmp, fixed = TRUE)) {
          tmp <- gsub("seconds (Sampling)", "", tmp, fixed = TRUE)
          sampling_time <- as.numeric(tmp)
        } else if (grepl("(Total)", tmp, fixed = TRUE)) {
          tmp <- gsub("seconds (Total)", "", tmp, fixed = TRUE)
          total_time <- as.numeric(tmp)
        }
      }
    }
  }
  if (length(csv_file_info$sampler_diagnostics) == 0 &&
      length(csv_file_info$model_params) == 0) {
    stop("Supplied CSV file does not contain any variable names or data!", call. = FALSE)
  }
  if (inv_metric_rows > 0 && csv_file_info$metric == "dense_e") {
    rows <- inv_metric_rows
    cols <- length(csv_file_info$inv_metric)/inv_metric_rows
    dim(csv_file_info$inv_metric) <- c(rows,cols)
  }

  # rename from old cmdstan names to new cmdstanX names
  csv_file_info$model_name <- csv_file_info$model
  csv_file_info$adapt_engaged <- csv_file_info$engaged
  csv_file_info$adapt_delta <- csv_file_info$delta
  csv_file_info$max_treedepth <- csv_file_info$max_depth
  csv_file_info$step_size <- csv_file_info$stepsize
  csv_file_info$iter_warmup <- csv_file_info$num_warmup
  csv_file_info$iter_sampling <- csv_file_info$num_samples
  if (csv_file_info$method == "variational" || csv_file_info$method == "optimize") {
    csv_file_info$threads <- csv_file_info$num_threads
  } else {
    csv_file_info$threads_per_chain <- csv_file_info$num_threads
  }
  if (csv_file_info$method == "sample") {
    csv_file_info$time <- data.frame(
      chain_id = csv_file_info$id,
      warmup = warmup_time,
      sampling = sampling_time,
      total = total_time
    )
  }
  csv_file_info$model <- NULL
  csv_file_info$engaged <- NULL
  csv_file_info$delta <- NULL
  csv_file_info$max_depth <- NULL
  csv_file_info$stepsize <- NULL
  csv_file_info$num_warmup <- NULL
  csv_file_info$num_samples <- NULL
  csv_file_info$file <- NULL
  csv_file_info$diagnostic_file <- NULL
  csv_file_info$metric_file <- NULL
  csv_file_info$num_threads <- NULL

  csv_file_info
}

#' Check that the sampling information from two CSV files matches.
#' Will throw errors if the sampling information doesn't match. If
#' it returns, the sampling information matches.
#'
#' @noRd
#' @param a,b Two lists returned by `read_csv_metadata()` to compare.
#'
check_csv_metadata_matches <- function(a, b) {
  if (a$model_name != b$model_name) {
    return(list(error = "Supplied CSV files were not generated with the same model!"))
  }
  if (a$method != b$method) {
    return(list(error = "Supplied CSV files were produced by different methods and need to be read in separately!"))
  }
  if ((length(a$model_params) != length(b$model_params)) ||
      !(all(a$model_params == b$model_params) &&
        all(a$sampler_diagnostics == b$sampler_diagnostics))) {
    return(list(error = "Supplied CSV files have samples for different variables!"))
  }
  if (a$method == "sample") {
    if (a$iter_sampling != b$iter_sampling ||
        a$thin != b$thin ||
        a$save_warmup != b$save_warmup ||
        (a$save_warmup == 1 && a$iter_warmup != b$iter_warmup)) {
      return(list(error = "Supplied CSV files do not match in the number of output samples!"))
    }
  } else if (a$method == "variational") {
    if (a$output_samples != b$output_samples) {
      return(list(error = "Supplied CSV files do not match in the number of output samples!"))
    }
  }
  match_list <- c("stan_version_major", "stan_version_minor", "stan_version_patch", "gamma", "kappa",
                  "t0", "init_buffer", "term_buffer", "window", "algorithm", "engine", "max_treedepth",
                  "metric", "stepsize_jitter", "adapt_engaged", "adapt_delta", "iter_warmup")
  not_matching <- c()
  for (name in names(a)) {
    if ((name %in% match_list) && (is.null(b[[name]]) ||  all(a[[name]] != b[[name]]))) {
      not_matching <- c(not_matching, name)
    }
  }
  list(not_matching = not_matching)
}

bind_list_of_draws_array <- function(draws, along = "chain") {
  if (!is.null(draws) && length(draws) > 0) {
    if (length(draws) > 1) {
      draws <- lapply(draws, posterior::as_draws_array)
      draws[["along"]] <- along
      draws <- do.call(posterior::bind_draws, draws)
    } else {
      draws <- posterior::as_draws_array(draws[[1]])
    }    
  } else {
    draws <- NULL
  }
  draws
}

# convert names like beta.1.1 to beta[1,1]
repair_variable_names <- function(names) {
  names <- sub("\\.", "[", names)
  names <- gsub("\\.", ",", names)
  names[grep("\\[", names)] <-
    paste0(names[grep("\\[", names)], "]")
  names
}

# convert names like beta[1,1] to beta.1.1
unrepair_variable_names <- function(names) {
  names <- sub("\\[", "\\.", names)
  names <- gsub(",","\\.",  names)
  names <- gsub("\\]","",  names)
  names
}

remaining_columns_to_read <- function(requested, currently_read, all) {
  if (is.null(requested)) {
    if (is.null(all)) {
      return(NULL)
    }
    requested <- all
  }
  if (!any(nzchar(requested))) {
    return(requested)
  }
  if (is.null(all)) {
    unread <- requested[!(requested %in% currently_read)]
  } else {
    all_remaining <- all[!(all %in% currently_read)]
    unread <- c()
    for (p in requested) {
      if (any(all_remaining == p)) {
        unread <- c(unread, p)
      }
      is_unread_element <- startsWith(all_remaining, paste0(p,"["))
      if (any(is_unread_element)) {
        unread <- c(unread, all_remaining[is_unread_element])
      }
    }
  }
  if (length(unread)) {
    unique(unread)
  } else {
    ""
  }
}
