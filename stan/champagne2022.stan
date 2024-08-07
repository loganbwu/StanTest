// structure based on https://mc-stan.org/users/documentation/case-studies/boarding_school_case_study.html

functions {
  real[] champagne(real t, real[] y, real[] theta, real[] x_r, int[] x_i) {
    
    real Il = y[1];
    real I0 = y[2];
    real Sl = y[3];
    real S0 = y[4];
    real CumulativeInfections = y[5];
    
    real r = x_r[1];
    real gammal = x_r[2];
    real f = x_r[3];
    real alpha = x_r[4];
    real beta = x_r[5];
    real delta = x_r[6];
    
    real infect = (theta[1] + delta) * (Il + I0);
    
    real dIl_dt = (1-alpha)*infect*(S0+Sl) + infect*I0 + (1-alpha)*f*Sl - gammal*Il - r*Il;
    real dI0_dt = -infect*I0 + gammal*Il - r*I0;
    real dSl_dt = -(1-alpha*(1-beta))*(infect+f)*Sl + alpha*(1-beta)*infect*S0 - gammal*Sl + r*Il;
    real dS0_dt = -(1-alpha*beta)*infect*S0 + infect*alpha*beta*Sl + alpha*beta*f*Sl + gammal*Sl + r*I0;
    real dCumulativeInfections = infect*(S0+Sl) + f*Sl;
    
    return {dIl_dt, dI0_dt, dSl_dt, dS0_dt, dCumulativeInfections};
  }
}

data {
  int<lower=1> n_times;
  real<lower=0> y0[5];
  real t0;
  real ts[n_times];
  int N;
  int cases[n_times];
  real<lower=0> r;
  real<lower=0> gammal;
  real<lower=0> f;
  real<lower=0, upper=1> alpha;
  real<lower=0, upper=1> beta;
  real<lower=0> delta;
  real<lower=0> lambda_lower;
  real<lower=0> lambda_upper;
}

transformed data {
  real x_r[6] = {
    r,
    gammal,
    f,
    alpha,
    beta,
    delta
  };
  int x_i[1] = { N };
  
  // We need to add an extra timepoint before to make difference calculations valid
  real ts_extended[n_times+1];
  real dt = ts[2] - ts[1];
  ts_extended[1] = ts[1] - dt;
  for (i in 1:n_times) {
    ts_extended[i+1] = ts[i];
  }
}

parameters {
  real<lower=lambda_lower, upper=lambda_upper> lambda;
  real<lower=0> phi_inv;
}

transformed parameters{
  real y[n_times+1, 5];
  real<lower=0> incidence[n_times];
  real phi = 1. / phi_inv;
  {
    real theta[1];
    theta[1] = lambda;
    
    y = integrate_ode_bdf(champagne, y0, t0, ts_extended, theta, x_r, x_i);
  }
  
  for (i in 1:n_times) {
    incidence[i] = fmax(1e-12, (y[i+1, 5] - y[i, 5]) * N * alpha);
  }
}

model {
  //priors
  lambda ~ exponential(1);
  phi_inv ~ exponential(5);
  
  //sampling distribution
  for (i in 1:n_times) {
    cases[i] ~ neg_binomial_2(incidence[i], phi);
  }
}

generated quantities {
  real sim_cases[n_times];
  
  for (i in 1:n_times) {
    sim_cases[i] = neg_binomial_2_rng(incidence[i], phi);
  }
}
