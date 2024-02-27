// These models are for testing a variable-length chain of delays in an ODE model

// Changes from v2: omega is now 'suitability' function and equations are verified against the clinical pathways
// Changes from v3: changed observation model for cases/relapses

functions {
  real suitability(real t, real eps, real kappa, real phase) {
    return(eps + (1-eps)*pi()/beta(0.5, kappa+0.5)*((1+sin(2*pi()*(t - phase)/365.25))/2)^kappa);
  }
  
  vector my_ode(real time, vector y, vector theta, real[] x_r, int[] x_i) {
    
    // Unpack theta
    real lambda = theta[1];
    
    // Unpack x_r
    real alpha = x_r[1];
    real beta = x_r[2];
    real relapse_clinical_immunity = x_r[3];
    real gamma_d = x_r[4];
    real gamma_l = x_r[5];
    real delta = x_r[6];
    real phi = x_r[7];
    real f = x_r[8];
    real r = x_r[9];
    real p_long = x_r[10];
    real p_silent = x_r[11];
    real population_size = x_r[12];
    real eps = x_r[13];
    real kappa = x_r[14];
    real phase = x_r[15];
    
    // Unpack x_i
    int n_dormant = x_i[1];
    
    // Convenience quantities
    int n_stages = n_dormant + 1;
    int n_compartments = 2 + 3*n_stages;
    int active = n_dormant + 1;
    real recover = r;
    real silent = p_silent;
    real primary = 1 - p_silent;
    real treatedprimary = alpha;
    real untreatedprimary = 1-treatedprimary;
    real treatedsilent = 0;
    real untreatedsilent = 1-treatedsilent;
    real treatedrelapse = treatedprimary * (1-relapse_clinical_immunity); // This should change and/or be a fit variable
    real untreatedrelapse = 1-treatedrelapse;
    real complete = beta;
    real incomplete = 1-beta;
    real clear_d = gamma_d;
    real clear_l = gamma_l;
    real advance = delta*n_dormant;
    real relapse = f;
    real long_hyp = p_long;
    real short_hyp = 1-long_hyp;
    
    // Give reasonable names to variables
    real S0 = y[1];
    real I0 = y[2];
    array[n_stages] real Sl;
    array[n_stages] real Scl;
    array[n_stages] real Icl;
    for (i in 1:n_stages) {
      Sl[i] = y[2+i];
      Scl[i] = y[2+n_stages+i];
      Icl[i] = y[2+2*n_stages+i];
    }
    
    // Force of infection
    real infect = lambda * suitability(time, eps, kappa, phase) * (I0 + sum(Icl)) + phi;
    
    // Compute derivatives
    // S0
    real dS0dt = -S0*infect*(short_hyp*(treatedprimary*incomplete+untreatedprimary) + long_hyp*(primary*(treatedprimary*incomplete + untreatedprimary) + silent*(treatedsilent*incomplete + untreatedsilent))) +
      sum(Sl)*(infect*(short_hyp*treatedprimary*complete+long_hyp*(primary*treatedprimary*complete+silent*treatedsilent*complete))) +
      Sl[active]*relapse*treatedprimary*complete +
      sum(Sl[1:n_dormant])*clear_d +
      Sl[active]*clear_l +
      sum(Scl)*infect*(short_hyp*treatedprimary*complete + long_hyp*(primary*treatedprimary*complete + silent*treatedsilent*complete)) +
      Scl[active]*relapse*treatedrelapse*complete +
      sum(Scl[1:n_dormant])*clear_d +
      Scl[active]*clear_l +
      I0*recover;
    
    // Sl
    real dSldt[n_stages];
    dSldt[1] = -Sl[1]*(infect*(short_hyp + long_hyp*(primary + silent*treatedsilent*complete)) + advance + clear_d) +
      S0*infect*long_hyp*silent*(treatedsilent*incomplete + untreatedsilent);
    for (i in 2:n_stages-1) {
      dSldt[i] = -Sl[i]*(infect*(short_hyp + long_hyp*(primary + silent*treatedsilent*complete)) + advance + clear_d) +
      Sl[i-1]*advance;
    }
    dSldt[n_stages] = -Sl[n_stages]*(infect*(short_hyp + long_hyp*(primary + silent*treatedsilent*complete)) + relapse + clear_l) +
      Sl[n_stages-1]*advance;
    
    // Scl
    real dScldt[n_stages];
    dScldt[1] = -Scl[1]*(infect*(short_hyp + long_hyp*(primary*(treatedprimary*complete + untreatedprimary) + silent*treatedsilent*complete)) + advance + clear_d) +
      S0*infect*long_hyp*primary*treatedprimary*incomplete +
      Sl[1]*infect*long_hyp*primary*treatedprimary*incomplete +
      Icl[1]*recover;
    for (i in 2:n_stages-1) {
      dScldt[i] = -Scl[i]*(infect*(short_hyp + long_hyp*(primary*(treatedprimary*complete + untreatedprimary) + silent*treatedsilent*complete)) + advance + clear_d) +
        Scl[i-1]*advance +
        Sl[i]*infect*long_hyp*primary*treatedprimary*incomplete +
        Icl[i]*recover;
    }
    dScldt[n_stages] = -Scl[n_stages]*(infect*(short_hyp*(treatedprimary*complete + untreatedprimary) + long_hyp*(primary*(treatedprimary*complete + untreatedprimary) + silent*treatedsilent*complete)) + relapse*(treatedrelapse*complete+untreatedrelapse) + clear_l) +
      S0*infect*short_hyp*treatedprimary*incomplete +
      sum(Sl)*infect*short_hyp*treatedprimary*incomplete +
      Sl[n_stages]*infect*long_hyp*primary*treatedprimary*incomplete +
      Sl[n_stages]*relapse*treatedprimary*incomplete +
      sum(Scl[1:n_dormant])*infect*short_hyp*treatedprimary*incomplete +
      Scl[n_stages-1]*advance +
      Icl[n_stages]*recover;
    
    // I0
    real dI0dt = -I0*(infect + recover) +
      sum(Icl[1:n_dormant])*clear_d +
      Icl[active]*clear_l;
    
    // Icl
    real dIcldt[n_stages];
    dIcldt[1] = -Icl[1]*(infect*short_hyp + advance + clear_d + recover) +
      S0*(infect*long_hyp*primary*untreatedprimary) +
      Sl[1]*infect*long_hyp*primary*untreatedprimary +
      Scl[1]*infect*long_hyp*primary*untreatedprimary +
      I0*infect*long_hyp;
    for (i in 2:n_stages-1) {
      dIcldt[i] = -Icl[i]*(infect*short_hyp + advance + clear_d + recover) +
      Sl[i]*infect*long_hyp*primary*untreatedprimary +
      Scl[i]*infect*long_hyp*primary*untreatedprimary +
      Icl[i-1]*advance;
    }
    dIcldt[n_stages] = -Icl[n_stages]*(clear_l+recover) +
      S0*infect*short_hyp*untreatedprimary +
      sum(Sl)*infect*short_hyp*untreatedprimary +
      Sl[n_stages]*infect*long_hyp*primary*untreatedprimary +
      Sl[n_stages]*relapse*untreatedprimary +
      sum(Scl)*infect*short_hyp*untreatedprimary +
      Scl[n_stages]*infect*long_hyp*primary*untreatedprimary +
      Scl[n_stages]*relapse*untreatedrelapse +
      I0*infect*short_hyp +
      sum(Icl[1:n_dormant])*infect*short_hyp +
      Icl[n_stages-1]*advance;
    
    // A clinical case is defined by the number of treatments. It is not affected by the outcome of treatment.
    real dClinicalPrimary = (S0*infect*(short_hyp*treatedprimary + long_hyp*primary*treatedprimary) +
      sum(Sl)*infect*(short_hyp*treatedprimary + long_hyp*primary*treatedprimary) +
      sum(Scl)*infect*(short_hyp*treatedprimary + long_hyp*primary*treatedprimary)) * population_size;
      
    real dClinicalRelapse = (Sl[active]*relapse*treatedprimary +
      Scl[active]*relapse*treatedrelapse) * population_size;
    
    // Assign derivatives
    vector[num_elements(y)] dydt;
    dydt[1] = dS0dt;
    dydt[2] = dI0dt;
    for (i in 1:n_stages) {
      dydt[2+i] = dSldt[i];
      dydt[2+n_stages+i] = dScldt[i];
      dydt[2+2*n_stages+i] = dIcldt[i];
    }
    dydt[n_compartments+1] = dClinicalPrimary;
    dydt[n_compartments+2] = dClinicalRelapse;
    
    return dydt;
  }
}

data {
  int<lower=1> n_times;
  real t0;
  real ts[n_times];
  int cases[n_times];
  
  real<lower=0, upper=1> alpha;
  real<lower=0, upper=1> beta;
  real<lower=0, upper=1> relapse_clinical_immunity;
  real<lower=0> gamma_d;
  real<lower=0> gamma_l;
  real<lower=0> delta;
  real<lower=0> phi;
  real<lower=0> f;
  real<lower=0> r;
  real<lower=0, upper=1> p_long;
  real<lower=0, upper=1> p_silent;
  real<lower=0> population_size;
  real<lower=0, upper=1> eps;
  real<lower=0> kappa;
  real phase;
  
  int<lower=1> n_dormant;
  
  vector[2 + 3*(n_dormant+1) + 2] y0; # last element is clinical incidence
  int<lower=0, upper=1> run_estimation; // https://khakieconomics.github.io/2017/04/30/An-easy-way-to-simulate-fake-data-in-stan.html
}

transformed data {
  real x_r[15] = {
    alpha,
    beta,
    relapse_clinical_immunity,
    gamma_d,
    gamma_l,
    delta,
    phi,
    f,
    r,
    p_long,
    p_silent,
    population_size,
    eps,
    kappa,
    phase
  };
  
  int x_i[1] = {
    n_dormant
  };
  
  int n_stages = n_dormant + 1;
  int n_compartments = 2 + 3*n_stages;
  int len_y = n_compartments + 2;
}

parameters {
  real<lower=0> lambda;
}

transformed parameters {
  vector[1] theta;
  theta[1] = lambda;
  
  array[n_times] vector[len_y] y = ode_bdf(my_ode, y0, t0, ts, theta, x_r, x_i);
}

model {
  theta[1] ~ exponential(5);
  real clinicalincidence;
  
  if (run_estimation == 1) {
    for (i in 2:n_times) {
      clinicalincidence = y[i][n_compartments+1] - y[i-1][n_compartments+1] +
        y[i][n_compartments+2] - y[i-1][n_compartments+2];
      cases[i] ~ poisson(fmax(1e-12, clinicalincidence));
    }
  }
}

generated quantities {
  vector[n_times] cases_sim;
  real clinicalincidence;
  for (i in 2:n_times) {
      clinicalincidence = y[i][n_compartments+1] - y[i-1][n_compartments+1] +
        y[i][n_compartments+2] - y[i-1][n_compartments+2];
    cases_sim[i] = poisson_rng(fmin(1e6, fmax(1e-12, clinicalincidence)));
  }
}
