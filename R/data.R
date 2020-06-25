#' Write data to a JSON file readable by CmdStan
#'
#' @export
#' @param data A named list of \R objects.
#' @param file A string specifying the path to where the data file should be
#'   written.
#'
#' @examples
#' x <- matrix(rnorm(10), 5, 2)
#' y <- rpois(nrow(x), lambda = 10)
#' z <- c(TRUE, FALSE)
#' data <- list(N = nrow(x), K = ncol(x), x = x, y = y, z = z)
#'
#' # write data to json file
#' file <- tempfile(fileext = ".json")
#' write_stan_json(data, file)
#'
#' # check the contents of the file
#' cat(readLines(file), sep = "\n")
#'
write_stan_json <- function(data, file) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Please install the 'jsonlite' package.", call. = FALSE)
  }
  if (!is.character(file) || !nzchar(file)) {
    stop("The supplied filename is invalid!", call. = FALSE)
  }

  for (var_name in names(data)) {
    var <- data[[var_name]]
    if (!(is.numeric(var) || is.factor(var) || is.logical(var) ||
          is.data.frame(var) || is.list(var))) {
      stop("Variable '", var_name, "' is of invalid type.", call. = FALSE)
    }

    if (is.logical(var)) {
      mode(var) <- "integer" # convert TRUE/FALSE to 1/0
    } else if (is.data.frame(var)) {
      var <- data.matrix(var)
    } else if (is.list(var)) {
      var <- list_to_array(var)
    }
    data[[var_name]] <- var
  }

  # call to write JSON with
  # unboxing variables (N = 10 is stored as N : 10, not N: [10])
  # handling factors as integers
  jsonlite::write_json(
    data,
    path = file,
    auto_unbox = TRUE,
    factor = "integer",
    digits = NA,
    pretty = TRUE
  )
}


list_to_array <- function(x) {
  list_length <- length(x)
  if (list_length == 0 ) return(NULL)
  element_dim <- length(x[[1]])
  check_equal_dim <- function(x, target_dim) { !is.null(element_dim) && length(x) == target_dim }
  all_same_size <- all(sapply(x, check_equal_dim, target_dim = element_dim))
  if (!all_same_size) {
    stop("All matrices/vectors in the list must be the same size!", call. = FALSE)
  }
  all_numeric <- all(sapply(x, function(a) is.numeric(a)))
  if (!all_numeric) {
    stop("All elements of the list must be numeric!", call. = FALSE)
  }
  element_num_of_dim <- length(element_dim)
  x <- unlist(x)
  dim(x) <- c(element_dim, list_length)
  aperm(x, c(element_num_of_dim + 1L, seq_len(element_num_of_dim)))
}


#' Process data for CmdStanModel methods
#'
#' @noRd
#' @param data If not `NULL`, then either a path to a data file compatible with
#'   CmdStan, or a named list of \R objects to pass to [write_stan_json()].
#' @return Path to data file.
process_data <- function(data) {
  if (is.null(data)) {
    path <- data
  } else if (is.character(data)) {
    path <- absolute_path(data)
  } else if (is.list(data) && !is.data.frame(data)) {
    if (cmdstan_version() < "2.22" && any_zero_dims(data)) {
      stop(
        "Data includes 0-dimensional data structures. To use this data please ",
        "either update your CmdStan installation with install_cmdstan() ",
        "or specify data as a file created by rstan::stan_rdump().",
        call. = FALSE
      )
    }
    path <- tempfile(pattern = "standata-", fileext = ".json")
    write_stan_json(data = data, file = path)
  } else {
    stop("'data' should be a path or a named list.", call. = FALSE)
  }
  path
}

# check if any objects in the data list have zero
any_zero_dims <- function(data) {
  has_zero_dims <- sapply(data, function(x) {
    any(dim(x) == 0)
  })
  any(has_zero_dims)
}
