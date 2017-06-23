library(testthat)
library(nlmixr)
library(data.table)

context("NLME: two-compartment infusion Michaelis-Menten, multiple-dose")

if (identical(Sys.getenv("NLMIXR_VALIDATION"), "true")) {
  
  test_that("ODE", {

    datr <-
      read.csv("INFUSION_2CPTMM.csv",
               header = TRUE,
               stringsAsFactors = F)
    datr$EVID <- ifelse(datr$EVID == 1, 10101, datr$EVID)
    datr <- data.table(datr)
    datr <- datr[EVID != 2]
    datIV <- datr[AMT > 0][, TIME := TIME + AMT / RATE][, AMT := -1 * AMT]
    datr <- rbind(datr, datIV)
    setkey(datr, ID, TIME)
    
    runno <- "N056"
    
    dat <- datr
    
    ode2MM <- "
    d/dt(centr)  = K21*periph-K12*centr-(VM*centr/V)/(KM+centr/V);
    d/dt(periph) =-K21*periph+K12*centr;
    "
    
    mypar7 <- function(lVM, lKM, lV, lCLD, lVT)
    {
      VM <- exp(lVM)
      KM <- exp(lKM)
      V <- exp(lV)
      CLD  <- exp(lCLD)
      VT <- exp(lVT)
      K12 <- CLD / V
      K21 <- CLD / VT
    }
    
    specs7 <-
      list(
        fixed = lVM + lKM + lV + lCLD + lVT ~ 1,
        random = pdDiag(lVM + lKM + lV + lCLD + lVT ~ 1),
        start = c(
          lVM = 7,
          lKM = 6,
          lV = 4,
          lCLD = 1.5,
          lVT = 4
        )
      )
    
    fit <-
      nlme_ode(
        dat,
        model = ode2MM,
        par_model = specs7,
        par_trans = mypar7,
        response = "centr",
        response.scaler = "V",
        verbose = TRUE,
        weight = varPower(fixed = c(1)),
        control = nlmeControl(pnlsTol = .1, msVerbose = TRUE)
      )
    
    z <- VarCorr(fit)
    
    expect_equal(signif(as.numeric(fit$logLik), 6),-44059.4)
    expect_equal(signif(AIC(fit), 6), 88140.7)
    expect_equal(signif(BIC(fit), 6), 88216)
    
    expect_equal(signif(as.numeric(fit$coefficients$fixed[1]), 3), 6.94)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[2]), 3), 5.53)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[3]), 3), 4.26)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[4]), 3), 1.23)
    expect_equal(signif(as.numeric(fit$coefficients$fixed[5]), 3), 3.91)
    
    expect_equal(signif(as.numeric(z[1, "StdDev"]), 3), 0.351)
    expect_equal(signif(as.numeric(z[2, "StdDev"]), 3), 0.357)
    expect_equal(signif(as.numeric(z[3, "StdDev"]), 3), 0.292)
    expect_equal(signif(as.numeric(z[4, "StdDev"]), 3), 0.000307)
    expect_equal(signif(as.numeric(z[5, "StdDev"]), 3), 0.000103)
    
    expect_equal(signif(fit$sigma, 3), 0.207)
  })
  
}