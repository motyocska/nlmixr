library(testthat)
library(nlmixr)

context("NLME70: two-compartment oral Michaelis-Menten, multiple-dose")

if (identical(Sys.getenv("NLMIXR_VALIDATION"), "true")) {
  
  test_that("ODE", {

    datr <-
      read.csv("Oral_2CPTMM.csv",
               header = TRUE,
               stringsAsFactors = F)
    datr$EVID <- ifelse(datr$EVID == 1, 101, datr$EVID)
    datr <- datr[datr$EVID != 2,]
    
    ode2MMKA <- "
    d/dt(abs)    =-KA*abs;
    d/dt(centr)  = KA*abs+K21*periph-K12*centr-(VM*centr/V)/(KM+centr/V);
    d/dt(periph) =-K21*periph+K12*centr;
    "
    
    mypar9 <- function(lVM, lKM, lV, lCLD, lVT, lKA)
    {
      VM <- exp(lVM)
      KM <- exp(lKM)
      V <- exp(lV)
      CLD  <- exp(lCLD)
      VT <- exp(lVT)
      KA <- exp(lKA)
      K12 <- CLD / V
      K21 <- CLD / VT
    }

    specs9 <-
      list(
        fixed = lVM + lKM + lV + lCLD + lVT + lKA ~ 1,
        random = pdDiag(lVM + lKM + lV + lCLD + lVT + lKA ~ 1),
        start = c(
          lVM = 7,
          lKM = 6,
          lV = 4,
          lCLD = 1.5,
          lVT = 4,
          lKA = 0.1
        )
      )
    
    runno <- "N070"
    
    dat <- datr
    
    fit <-
      nlme_ode(
        dat,
        model = ode2MMKA,
        par_model = specs9,
        par_trans = mypar9,
        response = "centr",
        response.scaler = "V",
        verbose = TRUE,
        weight = varPower(fixed = c(1)),
        control = nlmeControl(pnlsTol = .1, msVerbose = TRUE)
      )
    
    z <- VarCorr(fit)
    
    expect_equal(signif(as.numeric(fit$logLik), 6),-41276.7)
    expect_equal(signif(AIC(fit), 6), 82579.4)
    expect_equal(signif(BIC(fit), 6), 82668.5)
    
    expect_equal(signif(as.numeric(fit$coefficients$fixed[1]), 3), 6.88)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[2]), 3), 5.48)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[3]), 3), 4.27)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[4]), 3), 1.37)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[5]), 3), 3.82)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[6]), 3), 0.029)
    
    expect_equal(signif(as.numeric(z[1, "StdDev"]), 3), 0.306)
    expect_equal(signif(as.numeric(z[2, "StdDev"]), 3), 2.84e-07)
    expect_equal(signif(as.numeric(z[3, "StdDev"]), 3), 0.349)
    expect_equal(signif(as.numeric(z[4, "StdDev"]), 3), 0.000897)
    expect_equal(signif(as.numeric(z[5, "StdDev"]), 3), 0.295)
    expect_equal(signif(as.numeric(z[6, "StdDev"]), 3), 0.000487)
    
    expect_equal(signif(fit$sigma, 3), 0.208)
  })
  
}