# FUNCTIONS TO COMPUTE THE ASYMPTOTIC VARIANCE
# OF ESTIMATES FROM SIMPLE AND COVARIATE-ADAPTIVE RANDOMIZATION

# Gets the diagonal sandwich variance component
# for all linear models in the asymptotic variance formula.
#' @importFrom rlang .data
#' @importFrom dplyr mutate group_by summarize
vcov_sr_diag <- function(data, mod, residual=NULL){
  # Calculate the SD of the residuals from the model fit,
  # in order to compute sandwich variance -- this is
  # the asymptotic variance, not yet divided by n.
  if(is.null(residual)){
    residual <- stats::residuals(mod)
  }
  result <- dplyr::tibble(
    resid=residual,
    treat=data$treat
  ) %>%
    dplyr::group_by(.data$treat) %>%
    dplyr::summarize(se=stats::sd(.data$resid), .groups="drop") %>%
    dplyr::mutate(se=.data$se*sqrt(1/data$pie))

  return(diag(c(result$se)**2))
}

#' @importFrom rlang .data
#' @importFrom dplyr filter
get.erb <- function(model, data, mod, mu_hat=NULL){

  if(is.null(mu_hat)){
    mu_hat <- stats::predict(mod)
  }
  residual <- data$response - mu_hat

  # Calculate Omega Z under simple
  omegaz_sr <- omegaz.closure("simple")(data$pie)

  # Adjust this variance for Z

  # Calculate Omega Z under the covariate adaptive randomization scheme
  # Right now this will only be zero, but it's here for more generality
  # if we eventually include the urn design
  omegaz <- model$omegaz_func(data$pie)

  # Calculate the expectation of the residuals within each level of
  # car_strata variables Z
  dat <- dplyr::tibble(
    treat=data$treat,
    car_strata=data$joint_strata,
    resid=residual
  ) %>%
    dplyr::group_by(.data$treat, .data$car_strata) %>%
    dplyr::summarize(mean=mean(.data$resid), .groups="drop")

  # Calculate car_strata levels and proportions for
  # the outer expectation
  strata_levels <- data$joint_strata %>% levels
  strata_props <- data$joint_strata %>% table %>% proportions

  # Estimate R(B) by first getting the conditional expectation
  # vector for a particular car_strata (vector contains
  # all treatment groups), then dividing by the pi_t
  .get.cond.exp <- function(s) dat %>%
    dplyr::filter(.data$car_strata==s) %>%
    dplyr::arrange(.data$treat) %>%
    dplyr::pull(mean)

  .get.rb <- function(s) diag(.get.cond.exp(s) / c(data$pie))

  # Get the R(B) matrix for all car_strata levels
  rb_z <- lapply(strata_levels, .get.rb)

  # Compute the R(B)[Omega_{SR} - Omega_{Z_i}]R(B) | Z_i
  # for each Z_i
  rb_omega_rb_z <- lapply(rb_z, function(x) x %*% (omegaz_sr - omegaz) %*% x)

  # Compute the outer expectation
  ERB <- mapply(function(x, y) x*y, x=rb_omega_rb_z, y=strata_props, SIMPLIFY=FALSE)
  ERB <- Reduce("+", ERB)
  return(ERB)
}

# Gets AIPW asymptotic variance under simple randomization
vcov_car <- function(model, data, mod, mutilde){

  # Get predictions for observed treatment group
  preds <- matrix(nrow=data$n, ncol=1)
  for(t_id in 1:length(data$treat_levels)){
    t_group <- data$treat == data$treat_levels[t_id]
    preds[t_group] <- mutilde[, t_id][t_group]
  }

  # Compute residuals for the diagonal portion
  residual <- data$response - preds

  # Diagonal matrix of residuals for first component
  # diagmat <- vcov_sr_diag(data, mod, residual=residual)

  # Get covariance between observed Y and predicted \mu counterfactuals
  get.cov.Ya <- function(a){
    t_group <- data$treat == a
    cv <- stats::cov(data$response[t_group], mutilde[t_group, ])
    return(cv)
  }
  # Covariance matrix between Y and \mu
  cov_Ymu <- t(sapply(data$treat_levels, get.cov.Ya))

  # NEW: we are avoiding the situation where we have issues in estimating
  # the variance when many (or all) of the Y_a are zero in one group
  var_mutilde <- stats::var(mutilde)
  diag_mutilde <- diag(diag(var_mutilde))
  diag_covYmu <- diag(diag(cov_Ymu))
  diag_pi <- diag(1/c(data$pie))

  # New formula for variance calculation, doing a decomposition of variance
  # rather than calculating variance of residual
  diagmat <- vcov_sr_diag(data, mod, residual=data$response) +
    (diag_mutilde - 2 * diag_covYmu) * diag_pi

  # Sum of terms to compute simple randomization variance
  v <- diagmat + cov_Ymu + t(cov_Ymu) - stats::var(mutilde)

  # Adjust for Z if necessary
  if(!is.null(model$omegaz_func)) v <- v - get.erb(model, data, mod, mu_hat=preds)

  return(v)
}
