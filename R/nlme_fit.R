## nlme_fit.R: population PK/PD modeling library
##
## Copyright (C) 2014 - 2016  Wenping Wang
##
## This file is part of nlmixr.
##
## nlmixr is free software: you can redistribute it and/or modify it
## under the terms of the GNU General Public License as published by
## the Free Software Foundation, either version 2 of the License, or
## (at your option) any later version.
##
## nlmixr is distributed in the hope that it will be useful, but
## WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with nlmixr.  If not, see <http:##www.gnu.org/licenses/>.


nlmeModListEnv <- new.env(parent = emptyenv());

##' Access the model list information for nlmixr's nlme user functions
##'
##' @param x Parameter to get or set.  If this parameter is an
##'     environment, change the nlme model environment to this
##'     environment.
##' @param value Value of the parameter that is being set.
##' @return When both x and value are missing, this is the
##'     nlmeModListEnv.  When x is present and value is missing,
##'     return the value x in the current nlmeModListEnv.
##' @author Matthew L. Fidler
##' @keywords internal
##' @export
nlmeModList <- function(x, value){
  if (!missing(x) && !missing(value)){
    return(assign(x, value,  envir = nlmeModListEnv))
  } else if (!missing(x) && missing(value)){
    if (class(x) == "environment"){
      assignInMyNamespace("nlmeModListEnv", x);
    } else {
      return(get(x, envir = nlmeModListEnv))
    }
  } else {
    return(nlmeModListEnv);
  }
}

fmt_infusion_data <- function(dat) {
    x1 <- dat[dat$EVID>10000 & dat$AMT>0, ]
    x2 <- dat[dat$EVID>10000 & dat$AMT<0, ]
    x1$DUR <- x2$TIME - x1$TIME
    x1$AMT <- x1$AMT * x1$DUR
    x <- dat[dat$EVID < 10000, ]
    x$DUR <- NA
    x <- rbind(x, x1)
    ord <- order(x$ID, x$TIME, -x$EVID)
    x[ord,]
}

nlme_cmt_gen_usr_fn <- function(arg1, arg2, mc.cores){
    fun <- eval(parse(text=sprintf("function(%s, TIME, ID){NULL;}", arg1)))
    pkpars <- eval(parse(text=sprintf("bquote((nlmixr::nlmeModList(\"PKpars\"))(%s))", arg2)));
    body <- bquote({
        unlist(parallel::mclapply(as.character(unique(ID)), function(subj)
            {
                sel.d <- nlmixr::nlmeModList("ds")$ID==as.integer(subj)
                dose  <- nlmixr::nlmeModList("ds")[sel.d, "AMT"]
                dstm  <- nlmixr::nlmeModList("ds")[sel.d, "TIME"]
                Tinf  <- nlmixr::nlmeModList("ds")[sel.d, "DUR"]

                sel <- ID==subj
                time.subj <- TIME[sel]
                s <- .(pkpars)
                pkpars <- toupper(names(s))
                names(s) <- pkpars

                if (nlmixr::nlmeModList("oral")) {
                    if (is.element("TLAG", pkpars)) {
                        theta <- s[nlmixr::nlmeModList("refpars")]
                    } else {
                        theta <- c(s[nlmixr::nlmeModList("refpars")[1:(2*nlmixr::nlmeModList("ncmt")+1)]], 0)    #no TLAG, set to 0
                    }
                } else {
                    theta <- c(s[nlmixr::nlmeModList("refpars")[1:(2*nlmixr::nlmeModList("ncmt"))]], 0, 0)
                }

                cp <- lin_cmt(time.subj, dstm, dose, Tinf, theta, nlmixr::nlmeModList("oral"), nlmixr::nlmeModList("infusion"), nlmixr::nlmeModList("ncmt"), nlmixr::nlmeModList("parameterization"))
                cp
            }, mc.cores=.(mc.cores)))

    });
    body(fun) <- body;
    return(fun);
}

#' Fit nlme-based linear compartment mixed-effect model using closed form solution
#'
#' 'nlme_lin_cmpt' fits a linear one to three compartment model with
#' either first order absorption, or i.v. bolus, or i.v. infusion.  A
#' user specifies the number of compartments, route of drug
#' administrations, and the model parameterization. `nlmixr` supports
#' the clearance/volume parameterization and the micro constant
#' parameterization, with the former as the default.  Specification of
#' fixed effects, random effects and intial values follows the standard
#' nlme notations.
#'
#' @param dat data to be fitted
#' @param par_model list: model for fixed effects, randoms effects and initial values using nlme-type syntax.
#' @param ncmt numerical: number of compartments: 1-3
#' @param oral logical
#' @param infusion logical
#' @param tlag logical
#' @param parameterization numerical: type of parameterization, 1=clearance/volume, 2=micro-constants
#' @param par_trans function: calculation of PK parameters
#' @param mc.cores number of cores used in fitting (only for Linux)
#' @param ... additional nlme options
#' @return NULL
#' @author Wenping Wang
#' @examples
#' library(nlmixr)
#'
#' specs <- list(fixed=lKA+lCL+lV~1, random = pdDiag(lKA+lCL~1), start=c(lKA=0.5, lCL=-3.2, lV=-1))
#' fit <- nlme_lin_cmpt(theo_md, par_model=specs, ncmt=1, verbose=TRUE)
#' #plot(augPred(fit,level=0:1))
#' summary(fit)
#'
#' @export
nlme_lin_cmpt <- function(dat, par_model,
	ncmt, oral=TRUE, infusion=FALSE, tlag=FALSE, parameterization=1,
	par_trans=get.parfn(oral, ncmt, parameterization, tlag),
	mc.cores=1, ...)
{
    if(oral*infusion) {
        msg <- "oral and infusion cannot be all TRUE"
        stop(msg)
    }    #prep PKpars
    PKpars <- par_trans
	x <- deparse(body(PKpars))
	len <- length(x)
	x[len] <- "unlist(as.list(environment()))"
	x <- paste(c(x, "}"), collapse = "\n")
	body(PKpars) <- parse(text=x)

    #a new env with a ref in .GlobalEnv, holding model components
    #a hack due to non-std call by nlme
    ## assign("..ModList", new.env(parent=emptyenv()), envir=.GlobalEnv)

    #master par list
    pm <- list(
        c("CL", "V", "KA", "TLAG"),
        c("CL", "V", "CLD", "VT", "KA", "TLAG"),
        c("CL", "V", "CLD", "VT", "CLD2", "VT2", "KA", "TLAG"),
        c("KE", "V", "KA", "TLAG"),
        c("KE", "V", "K12", "K21", "KA", "TLAG"),
        c("KE", "V", "K12", "K21", "K13", "K31", "KA", "TLAG")
    )
    dim(pm)<-c(3,2)


    #gen user_fn

    s <- formals(PKpars)
    arg1 <- paste(names(s), collapse=", ")
    arg2 <- paste(unlist(lapply(names(s), function(x) paste(x,"=",x,"[sel][1]", sep=""))), collapse=", ")
    arg3 <- sprintf("list(%s)", paste(names(s), "=.1", collapse=", "))
    ## brew(text=cmt_fn_templ, output="fn.txt")
    ## source("fn.txt", local=nlmixr::nlmeModList())
    nlmixr::nlmeModList("user_fn", nlme_cmt_gen_usr_fn(arg1, arg2, mc.cores))

    refpars <- pm[[ncmt, parameterization]]
    npars <- length(refpars)
    s <- do.call(PKpars, eval(parse(text=arg3)))
    pkpars <- names(s)

    if (!oral) {
        refpars <- refpars[1:(npars-2)]
        pkpars.aug <- pkpars
    } else {
        pkpars.aug <- pkpars
        if(!is.element("TLAG", pkpars)) {
            pkpars.aug <- c(pkpars, "TLAG")
        }
    }
    notdefed <- setdiff(refpars, pkpars.aug)
    if(length(notdefed)) {
        msg <- paste(c("undefined PK pars:", notdefed, collapse=" "))
        stop(msg)
    }

    #data prep
    nlmixr::nlmeModList("oral", oral);
    nlmixr::nlmeModList("infusion", infusion);
    nlmixr::nlmeModList("ncmt", ncmt)
    nlmixr::nlmeModList("parameterization", parameterization);
    if (infusion) {
    	dat <- fmt_infusion_data(dat)
    } else {
    	dat$DUR <- -1
    }
    nlmixr::nlmeModList("ds", dat[dat$EVID>0, c("ID", "TIME", "AMT", "DUR")]);
    dat$DUR <- NULL
    dat <- dat[dat$EVID==0,]
    nlmixr::nlmeModList("dat.g", groupedData(DV~TIME|ID, dat));
    nlmixr::nlmeModList("PKpars", PKpars);
    nlmixr::nlmeModList("refpars", refpars);

    mod.specs <- list(model=as.formula(sprintf("DV ~ (nlmixr::nlmeModList(\"user_fn\"))(%s, TIME, ID)", arg1)),
                      data = nlmixr::nlmeModList("dat.g"), fixed=par_model$fixed, random = par_model$random,
                      start=par_model$start, ...);
    if (Sys.getenv("nlmixr_silent") == "TRUE"){
        ret <- NULL;
        cur.env <- environment()
        R.utils::captureOutput(assign("ret", collectWarnings(do.call(nlme, mod.specs)), , cur.env));
    } else {
        ret <- collectWarnings(do.call(nlme, mod.specs));
    }
    ret$env <- nlmeModListEnv;
    assignInMyNamespace("nlmeModListEnv", new.env(parent = emptyenv()));
    class(ret) <- c("nlmixr_nlme", class(ret));
    return(ret);
}

nlme_ode_gen_usr_fn <- function(arg1, arg2, transit_abs, atol, rtol, mc.cores){
    fun <- eval(parse(text=sprintf("function(%s, TIME, ID){NULL;}", arg1)))
    pkpars <- eval(parse(text=sprintf("bquote((nlmixr::nlmeModList(\"PKpars\"))(%s))", arg2)));
    body <- bquote({
        z <- parallel::mclapply(as.character(unique(ID)), function(subj)
                       {
                           sel <- ID==subj
                           plist <- .(pkpars)
                           inits <- plist$initCondition
                           plist$initCondition <- NULL
                           theta <- unlist(plist)

                           dati = subset(nlmixr::nlmeModList("dat.o"), id==as.integer(subj))
                           if (match("F1", names(theta), nomatch=0)) dati$amt = theta["F1"]*dati$amt
		           if (match("RATE", names(theta), nomatch=0)) dati = prepEv(dati, theta)
                           ev <- eventTable()
                           ev$import.EventTable(dati)

                           if (any(theta>1e38)) {
                               warning('large parameter values. may rewrite par_trans.')
                               print(theta)
                           }
                           if (nlmixr::nlmeModList("debugODE")) {
                               print(subj)
                               print(theta)
                           }

                           m <- nlmixr::nlmeModList("m1")$run(theta, ev, inits, transit_abs=.(transit_abs), atol=.(atol), rtol=.(rtol));
                           if (is.null(dim(m))) m = t(as.matrix(m))
                           den <- if(is.null(nlmixr::nlmeModList("response.scaler"))) 1 else theta[nlmixr::nlmeModList("response.scaler")]
                           m[, nlmixr::nlmeModList("response")]/den
                       }, mc.cores=.(mc.cores))
	unlist(z)
    });
    body(fun) <- body;
    return(fun);
}

prepEv = function(dati, theta)
{
  ds = dati$evid>0
  arr1 = with(dati[ds,], time + amt/theta["RATE"])
  arr2 = as.double(dati$time)
  nar1 = length(arr1)
  nar2 = length(arr2)
  arr3 = (1L:nar2)[ds]-1L  #with bolus, narr1 != narr3
  nar3 = length(arr3)
  nevt = nar1+nar2
  s = .C("mergeArrays", arr1, arr2, arr3, integer(nar1), double(nevt), nar1, nar2, nar3)
  datii = data.frame(time=s[[5]], evid=0, amt=0)
  wh = s[[3]]; datii$evid[wh] = 10101; datii$amt[wh] = theta["RATE"]
  wh = s[[4]]; datii$evid[wh] = 10101; datii$amt[wh] =-theta["RATE"]
  datii
}

#' Fit nlme-based mixed-effect model using ODE implementation
#'
#' 'nlme_ode' fits a mixed-effect model described using ordinary differential
#' equation (ODEs). The ODE-definition follows RxODE syntax.
#' Specification of fixed effects, random effects and intial values follows
#' the standard nlme notations.
#'
#' @param dat.o data to be fitted
#' @param model a string containing the set of ordinary differential equations (ODE) and other expressions defining the changes in the dynamic  system. For details, see the sections \dQuote{Details} and  \dQuote{\code{RxODE Syntax}} below.
#' @param par_model list: model for fixed effects, randoms effects and initial values.
#' @param par_trans function: calculation of PK parameters
#' @param response names of the response variable
#' @param response.scaler optional response variable scaler. default is NULL
#' @param transit_abs a logical if transit absorption model is enabled
#' @param atol atol (absolute tolerance for ODE-solver)
#' @param rtol rtol (relative tolerance for ODE-solver)
#' @param debugODE a logical if debugging is enabled
#' @param mc.cores number of cores used in fitting (only for Linux)
#' @param ... additional nlme options
#' @return NULL
#' @details
#'    The ODE-based model specification may be coded inside a character
#'    string or in a text file, see Section \emph{RxODE Syntax} below for
#'    coding details.  An internal \code{RxODE} compilation manager object
#'    translates the ODE system into C, compiles it, and dynamically loads the
#'    object code into the current R session.  The call to \code{RxODE}
#'    produces an object of class \code{RxODE} which consists of a list-like
#'    structure (closure) with various member functions (see Section
#'    \emph{Value} below).
#'
#' @section RxODE Syntax:
#'
#'    An \code{RxODE} model specification consists of one or more
#'    statements terminated by semi-colons, \sQuote{\code{;}}, and
#'    optional comments (comments are delimited by \code{#} and an
#'    end-of-line marker).  \strong{NB:} Comments are not allowed
#'    inside statements.
#'
#'    A block of statements is a set of statements delimited by
#'    curly braces, \sQuote{\code{\{ ... \}}}.
#'    Statements can be either assignments or conditional \code{if}
#'    statements. Assignment statements can be either \dQuote{simple}
#'    assignments, where the left hand is an identifier (i.e., variable), or
#'    special \dQuote{time-derivative} assignments, where the left hand
#'    specifies the change of that variable with respect to time
#'    e.g., \code{d/dt(depot)}.
#'
#'    Expressions in assignment and \sQuote{\code{if}} statements can be
#'    numeric or logical (no character expressions are currently supported).
#'    Numeric expressions can include the following numeric operators
#'    (\sQuote{\code{+}}, \sQuote{\code{-}}, \sQuote{\code{*}},
#'    \sQuote{\code{/}}, \sQuote{\code{^}}),   and
#'    those mathematical functions defined in the C or the
#'    R math libraries (e.g., \code{fabs}, \code{exp}, \code{log}, \code{sin}).
#'    (Note that the modulo operator \sQuote{\code{\%}} is currently
#'    not supported.)
#'
#'    Identifiers in an \code{RxODE} model specification can refer to:
#'    \itemize{
#'       \item state variables in the dynamic system (e.g., compartments in a
#'       pharmacokinetic/pharmacodynamic model);
#'       \item implied input variable, \code{t} (time),
#'       \code{podo} (oral dose, for absorption models), and
#'       \code{tlast} (last time point);
#'       \item model parameters, (\code{ka} rate of absorption, \code{CL}
#'       clearance, etc.);
#'       \item others, as created by assignments as part of the model
#'       specification.
#'    }
#'
#'    Identifiers consist of case-sensitive alphanumeric characters,
#'    plus the underscore \sQuote{_} character.  \strong{NB:} the
#'    dot \sQuote{.} character is \strong{not} a valid character
#'    identifier.
#'
#'    The values of these variables at pre-specified time points are
#'    saved as part of the fitted/integrated/solved model (see
#'    \code{\link{eventTable}}, in particular its member function
#'    \code{add.sampling} that defines a set of time points at which
#'    to capture a snapshot of the system via the values of these variables).
#'
#'    The ODE specification mini-language is parsed with the help of
#'    the open source tool \emph{DParser}, Plevyak (2015).
#' @author Wenping Wang
#' @examples
#' \dontrun{
#' library(nlmixr)
#' ode <- "
#' d/dt(depot) =-KA*depot;
#' d/dt(centr) = KA*depot - KE*centr;
#' "
#' dat <- read.table(system.file("examples/theo_md.txt", package = "nlmixr"), head=TRUE)
#' mypar <- function(lKA, lKE, lCL)
#' {
#'     KA=exp(lKA)
#'     KE=exp(lKE)
#'     CL=exp(lCL)
#'     V = CL/KE
#' }
#'
#' specs <- list(fixed=lKA+lKE+lCL~1, random = pdDiag(lKA+lCL~1),
#' 	start=c(lKA=0.5, lKE=-2.5, lCL=-3.2))
#' fit <- nlme_ode(dat, model=ode, par_model=specs, par_trans=mypar,
#' 	response="centr", response.scaler="V")
#'
#' }
#' @export
nlme_ode <- function(dat.o, model, par_model, par_trans,
	response, response.scaler=NULL,
	transit_abs = FALSE,
	atol=1.0e-8, rtol=1.0e-8,
	debugODE=FALSE, mc.cores=1, ...)
{
  if (any(dat.o$EVID[dat.o$EVID>0]<101))
    	stop("incompatible EVID values")

    #a new env with a ref in .GlobalEnv, holding model components
    #a hack due to non-std call by nlme
    ## assign("..ModList", new.env(), envir=.GlobalEnv)

    #prep ode
    if (class(model)=="RxODE") nlmixr::nlmeModList("m1", model)
    else if (class(model)=="character") {
        nlmixr::nlmeModList("m1", RxODE(model = model));
    } else {
      stop('invalid model input')
    }

    #prep PKpars
    PKpars <- par_trans
	x <- deparse(body(PKpars))
	len <- length(x)
	x[len] <- "as.list(environment())"
	x <- paste(c(x, "}"), collapse = "\n")
	body(PKpars) <- parse(text=x)

    #gen user_fn
    s <- formals(PKpars)
    arg1 <- paste(names(s), collapse=", ")
    arg2 <- paste(unlist(lapply(names(s), function(x) paste(x,"=",x,"[sel][1]", sep=""))), collapse=", ")

    nlmixr::nlmeModList("user_fn", nlme_ode_gen_usr_fn(arg1, arg2, transit_abs, atol, rtol, mc.cores));

    #data prep
    dat.g <- groupedData(DV~TIME|ID, subset(dat.o, dat.o$EVID==0))
    names(dat.o) <- tolower(names(dat.o))
  nlmixr::nlmeModList("response", response);
  nlmixr::nlmeModList("response.scaler", response.scaler);
  nlmixr::nlmeModList("dat.g", dat.g);
  nlmixr::nlmeModList("dat.o", dat.o);
  nlmixr::nlmeModList("PKpars", PKpars);
  nlmixr::nlmeModList("debugODE", debugODE);

  mod.specs <- list(model=as.formula(sprintf("DV ~ (nlmixr::nlmeModList(\"user_fn\"))(%s, TIME, ID)", arg1)),
                    data = nlmixr::nlmeModList("dat.g"), fixed=par_model$fixed, random = par_model$random,
                    start=par_model$start, ...)
  if (Sys.getenv("nlmixr_silent") == "TRUE"){
      ret <- NULL;
      cur.env <- environment()
      R.utils::captureOutput(assign("ret", collectWarnings(do.call(nlme, mod.specs)), , cur.env));
  } else {
      ret <- collectWarnings(do.call(nlme, mod.specs));
  }
  ret$env <- nlmeModListEnv;
  assignInMyNamespace("nlmeModListEnv", new.env(parent = emptyenv()));
  class(ret) <- c("nlmixr_nlme", class(ret));
  return(ret);
}

##' @export
print.nlmixr_nlme <- function (x, ..., print.data=FALSE)
{
  dd <- x$dims
  if (inherits(x, "nlme")) {
    cat("Nonlinear mixed-effects model fit by ")
    cat(ifelse(x$method == "REML", "REML\n", "maximum likelihood\n"))
    cat("  Model:", deparse(x$call$model), "\n")
  }
  else {
    cat("Linear mixed-effects model fit by ")
    cat(ifelse(x$method == "REML", "REML\n", "maximum likelihood\n"))
  }
  if (print.data)
    cat("  Data:", deparse(x$call$data), "\n")
  if (!is.null(x$call$subset)) {
    cat("  Subset:", deparse(asOneSidedFormula(x$call$subset)[[2L]]),
        "\n")
  }
  cat("  Log-", ifelse(x$method == "REML", "restricted-", ""),
      "likelihood: ", format(x$logLik), "\n", sep = "")
  fixF <- x$call$fixed
  if (inherits(fixF, "formula") || is.call(fixF) || is.name(fixF)) {
    cat("  Fixed:", deparse(x$call$fixed), "\n")
  }
  else {
    cat("  Fixed:", deparse(lapply(fixF, function(el) as.name(deparse(el)))),
        "\n")
  }
  print(nlme::fixef(x))
  cat("\n")
  print(summary(x$modelStruct), sigma = x$sigma)
  cat("Number of Observations:", dd[["N"]])
  cat("\nNumber of Groups: ")
  Ngrps <- dd$ngrps[1:dd$Q]
  if ((lNgrps <- length(Ngrps)) == 1) {
    cat(Ngrps, "\n")
  }
  else {
    sNgrps <- 1:lNgrps
    aux <- rep(names(Ngrps), sNgrps)
    aux <- split(aux, array(rep(sNgrps, lNgrps), c(lNgrps,
                                                   lNgrps))[!lower.tri(diag(lNgrps))])
    names(Ngrps) <- unlist(lapply(aux, paste, collapse = " %in% "))
    cat("\n")
    print(rev(Ngrps))
  }
  invisible(x)
}

##' @export
summary.nlmixr_nlme <- function(object, ...){
  tmp <- object;
  class(object) <- class(object)[-1];
  tmp <- summary(object);
  class(tmp) <- c("summary_nlmixr_nlme", class(tmp));
  return(tmp);
}

##' @export
print.summary_nlmixr_nlme <- function (x, verbose = FALSE, ..., print.data=FALSE)
{
  dd <- x$dims
  verbose <- verbose || attr(x, "verbose")
  if (inherits(x, "nlme")) {
    cat("Nonlinear mixed-effects model fit by ")
    cat(ifelse(x$method == "REML", "REML\n", "maximum likelihood\n"))
    cat("  Model:", deparse(x$call$model), "\n")
  }
  else {
    cat("Linear mixed-effects model fit by ")
    cat(ifelse(x$method == "REML", "REML\n", "maximum likelihood\n"))
  }
  if (print.data)
    cat(" Data:", deparse(x$call$data), "\n")
  if (!is.null(x$call$subset)) {
    cat("  Subset:", deparse(asOneSidedFormula(x$call$subset)[[2L]]),
        "\n")
  }
  print(data.frame(AIC = x$AIC, BIC = x$BIC, logLik = c(x$logLik),
                   row.names = " "))
  if (verbose) {
    cat("Convergence at iteration:", x$numIter, "\n")
  }
  cat("\n")
  print(summary(x$modelStruct), sigma = x$sigma, reEstimates = x$coef$random,
        verbose = verbose)
  cat("Fixed effects: ")
  fixF <- x$call$fixed
  if (inherits(fixF, "formula") || is.call(fixF)) {
    cat(deparse(x$call$fixed), "\n")
  }
  else {
    cat(deparse(lapply(fixF, function(el) as.name(deparse(el)))),
        "\n")
  }
  xtTab <- as.data.frame(x$tTable)
  wchPval <- match("p-value", names(xtTab))
  for (i in names(xtTab)[-wchPval]) {
    xtTab[, i] <- format(zapsmall(xtTab[, i]))
  }
  xtTab[, wchPval] <- format(round(xtTab[, wchPval], 4))
  if (any(wchLv <- (as.double(levels(xtTab[, wchPval])) ==
                      0))) {
    levels(xtTab[, wchPval])[wchLv] <- "<.0001"
  }
  row.names(xtTab) <- dimnames(x$tTable)[[1L]]
  print(xtTab)
  if (nrow(x$tTable) > 1) {
    corr <- x$corFixed
    class(corr) <- "correlation"
    print(corr, title = " Correlation:", ...)
  }
  cat("\nStandardized Within-Group Residuals:\n")
  print(x$residuals)
  cat("\nNumber of Observations:", x$dims[["N"]])
  cat("\nNumber of Groups: ")
  Ngrps <- dd$ngrps[1:dd$Q]
  if ((lNgrps <- length(Ngrps)) == 1) {
    cat(Ngrps, "\n")
  }
  else {
    sNgrps <- 1:lNgrps
    aux <- rep(names(Ngrps), sNgrps)
    aux <- split(aux, array(rep(sNgrps, lNgrps), c(lNgrps,
                                                   lNgrps))[!lower.tri(diag(lNgrps))])
    names(Ngrps) <- unlist(lapply(aux, paste, collapse = " %in% "))
    cat("\n")
    print(rev(Ngrps))
  }
  invisible(x)
}
##' @importFrom nlme varWeights
##' @export
varWeights.nlmixr_nlme <- function(object, ...){
    nlmixr::nlmeModList(object$env);
    on.exit({nlmixr::nlmeModList(new.env(parent = emptyenv()))})
    return(nlme::varWeights(object$modelStruct$varStruct))
}


##' @export
anova.nlmixr_nlme <- function(object, ...){
    args <- lapply(list(object, ...),
                   function(x){
        if (class(x)[1L] == "nlmixr_nlme"){
            tmp <- x;
            class(tmp) <- class(tmp)[-1L];
            return(tmp)
        } ## else if (is(x, "nlmixr.ui.nlme")){
        ##     x <- as.nlme(x);
        ##     if (class(x)[1L] == "nlmixr_nlme"){
        ##         tmp <- x;
        ##         class(tmp) <- class(tmp)[-1L];
        ##         return(tmp)
        ##     } else {
        ##         return(x)
        ##     }
        ## }
        else {
            return(x)
        }
    });
    ret <- do.call(getFromNamespace("anova.lme","nlme"), args);
    row.names(ret) <- NULL;
    return(ret);
}

##' @rdname focei.eta
focei.eta.nlmixr_nlme <- function(object, ...){
    mat <- as.matrix(VarCorr(object))
    dn <- dimnames(mat);
    d <- dim(mat);
    is.cov <- (d[2] >= 3);
    mat <- suppressWarnings(matrix(as.numeric(mat), d[1], d[2]));
    dimnames(mat) <- dn
    len <- length(mat[, 1, drop = FALSE]);
    mat <- mat[-len,, drop = FALSE]
    est <- as.numeric(mat[, 1]);
    etas <- sprintf("ETA[%d]", seq_along(row.names(est)))
    if (!is.cov)
        return(eval(parse(text=sprintf("list(%s)", paste(sprintf("ETA[%d] ~ %s", seq_along(est), est), collapse=", ")))));
    sd <- as.numeric(mat[-len, 2]);
    cor <- apply(mat[-c(1, len), -(1:2), drop = FALSE], 1, function(x){as.numeric(x)})
    ome <- diag(est)
    ## Now fill in the diagionals
    if (class(cor) == "matrix"){
        stop("Haven't handled covariance translation for this model yet...")
    } else {
        ome[1, 2] <- ome[2, 1] <- cor[1] * sd[1] * sd[2]
        eval(parse(text=sprintf("list(%s ~ c(%s))", paste(etas, collapse="+"),
                           paste(ome[lower.tri(ome, diag=TRUE)], collapse=", "))))
    }
}

##' @rdname focei.theta
focei.theta.nlmixr_nlme <- function(object, uif, ...){
    if (class(uif) == "function"){
        uif <- nlmixr(uif);
    }
    n <- uif$focei.names
    thetas <- rep(NA, length(n));
    names(thetas) <- n;
    f <- fixed.effects(object)
    for (n in names(f)){
        thetas[n] <- f[n];
    }
    ## Handle variance classes.
    err <- object$modelStruct$varStruct
    err.type <- uif$focei.err.type;
    if (is(err, "varConstPower")){
        ## Addititive + proportional
        add <- which(err.type == "add")
        prop <- which(err.type == "prop")
        thetas[prop] <- object$modelStruct$varStruct$const;
        thetas[add] <- object$sigma;
    } else if (is(err, "varPower")){
        ## Proportional
        prop <- which(err.type == "prop")
        thetas[prop] <- object$sigma
    } else {
        ## Additive.
        add <- which(err.type == "add")
        thetas[add] <- object$sigma
    }
    return(thetas)
}


##' @rdname as.focei
as.focei.nlmixr_nlme <- function(object, uif, pt=proc.time(), ..., data){
    if (class(uif) == "function"){
        uif <- nlmixr(uif);
    }
    uif.new <- uif;
    fit <- object;
    mat <- as.matrix(random.effects(fit));
    mat <- mat[order(as.numeric(row.names(mat))),, drop = FALSE]
    th <- focei.theta(fit, uif)
    for (n in names(th)){
        uif.new$est[uif.new$name == n] <- th[n];
    }
    ome <- focei.eta(fit, uif);
    init <- list(THTA=th,
                 OMGA=ome)
    nlme.time <- proc.time() - pt;
    if (missing(data)){
        dat <- as.data.frame(getData(object));
    } else {
        dat <- data;
    }
    fit.f <- focei.fit(data=dat,
                       inits=init,
                       PKpars=uif$theta.pars,
                       ## par_trans=fun,
                       model=uif$rxode.pred,
                       pred=function(){return(nlmixr_pred)},
                       err=uif$error,
                       lower=uif$focei.lower,
                       upper=uif$focei.upper,
                       theta.names=uif$focei.names,
                       eta.names=uif$eta.names,
                       control=list(NOTRUN=TRUE,
                                    inits.mat=mat,
                                    cores=1,
                                    find.best.eta=FALSE,
                                    ## numeric=(!is.null(uif$nmodel$lin.solved)),
                                    sum.prod=uif$env$sum.prod));
    ome <- fit.f$omega;
    w <- which(!is.na(uif.new$ini$neta1))
    for (i in w){
        uif.new$ini$est[i] <- ome[uif.new$ini$neta1[i], uif.new$ini$neta2[i]];
    }
    ## enclose the nlme fit in the .focei.env
    env <- attr(fit.f, ".focei.env");
    env$fit$nlme <- fit
    tmp <- cbind(data.frame(nlme=nlme.time["elapsed"]), env$fit$time);
    names(tmp) <- gsub("optimize", "FOCEi Evaulate", names(tmp))
    env$fit$time <- tmp;
    env$uif <- uif;
    env$uif.new <- uif.new;
    class(fit.f) <- c("nlmixr.ui.nlme", class(fit.f))
    return(fit.f)
}

## comparePred should work because predict should work...

##' @importFrom nlme nlme
##' @export
nlme.function <- function(model, data, fixed, random = fixed,
                          groups, start, correlation = NULL, weights = NULL, subset,
                          method = c("ML", "REML"), na.action = na.fail, naPattern,
                          control = list(), verbose = FALSE){
    uif <- nlmixr(model);
    call <- as.list(match.call(expand.dots=TRUE))[-1];
    call$model <- uif;
    return(do.call(getFromNamespace("nlme.nlmixrUI","nlmixr"), call, envir = parent.frame(1)))
}

##' @export
nlme.nlmixrUI <- function(model, data, fixed, random = fixed,
                          groups, start, correlation = NULL, weights = NULL, subset,
                          method = c("ML", "REML"), na.action = na.fail, naPattern,
                          control = list(), verbose = FALSE){
    call <- as.list(match.call(expand.dots=TRUE))[-1];
    names(call)[1] <- "object";
    call$est <- "nlme";
    return(do.call(getFromNamespace("nlmixr","nlmixr"), call, envir = parent.frame(1)))
}
##' @export
nlme.nlmixr.ui.nlme <- function(model, data, fixed, random = fixed,
                                groups, start, correlation = NULL, weights = NULL, subset,
                                method = c("ML", "REML"), na.action = na.fail, naPattern,
                                control = list(), verbose = FALSE){
    env <- attr(model, ".focei.env")
    uif <- env$uif.new;
    call <- as.list(match.call(expand.dots=TRUE))[-1];
    names(call)[1] <- "object";
    call$object <- uif
    call$est <- "nlme";
    if (missing(data)){
        data <- getData(model);
        call$data <- data
    }
    return(do.call(getFromNamespace("nlmixr","nlmixr"), call, envir = parent.frame(1)))
}

##' @export
nlme.nlmixr.ui.focei.fit <- nlme.nlmixr.ui.nlme
