library(R.utils)
library(tidyverse)
library(rstan)
library(parallel)
library(patchwork)
library(pbmcapply)
library(pbapply)
library(memoise)
library(RColorBrewer)
library(ggtext)
source("../R/constants.R")
source("../R/load_functions.R")

rstan_options(auto_write = TRUE, threads_per_chain = 1)

n_cores = parallelly::availableCores()
options(mc.cores = n_cores)
message("Running on ", n_cores, " cores")

# Load model and metropolis algorithm (copied from VivaxODE project folder)
source(file = "../R/models/temperate_v11.R")
source(file = "../R/functions/adaptive_metropolis.R")
# Load priors for each scenario
source(file = "../R/priors.R")
my_state_init = state_init_3
start_time = Sys.time()

china_selections = tribble(
  ~Region, ~min, ~max,
  "Dengzhou", "2004-01-01", "2009-01-01",
  "Guantang", "1977-01-01", "1982-01-01",
  "Huangchuan", NA, NA,
  "Xiayi", NA, NA
) %>%
  mutate(min = as.Date(min),
         max = as.Date(max))

if (!require(MalariaData)) {
  china_data = read_rds("china_data.rds")
} else {
  library(MalariaData)
  regions = c("Xiayi", "Guantang", "Dengzhou", "Huangchuan") %>% setNames({.})
  china_data_all = lapply(regions, function(x) {load_region(x, species = "Vivax", source="Local")}) %>%
    bind_rows(.id = "Region") %>%
    select(Region, Date, Cases) %>%
    left_join(china_selections, by="Region") %>%
    mutate(Date = as.Date(paste(year(Date), month(Date), "01", sep="-")) + months(1) - days(1)) %>% # Align to last day of the month
    mutate(include = ifelse(Date >= min & Date < max, "grey20", "grey"),
           include = replace_na(include, "grey"))
  
  china_data = china_data_all %>%
    filter(include == "grey20") %>%
    select(-include)
  
  write_rds(china_data, "china_data.rds")
}

data_baseline = list(
  t0 = -30*years,
  gamma_d = 1/434.,
  gamma_l = 1/223,
  f = 1/72,
  r = 1/60,
  eps = 0
)
# Add each scenario's data on
data_scenarios = lapply(seq_len(nrow(scenarios)), function(i) {
  data_scenario = data_baseline
  scenario_specific = scenarios[i,]
  for (name in names(scenario_specific)) {
    if (!is.character(scenario_specific[[name]])) {
      data_scenario[[name]] = scenario_specific[[name]]
    }
  }
  data_scenario$y0 = my_state_init(data_scenario, I0=0.01)
  
  # Add case data
  region_name = scenario_specific$region
  ts_region = china_data %>%
    filter(Region == region_name)
  first_year = min(year(ts_region$Date))
  ts_region = ts_region %>%
    mutate(ts = as.numeric(Date - as.Date(paste0(first_year, "-01-01"))))
  data_scenario$ts = ts_region$ts
  data_scenario$cases = ts_region$Cases
  return(data_scenario)
}) %>%
  setNames(scenarios$name)

# Define inits - start at the mean of all scenarios and the mean sd of all chains
init = c(
  alpha = 0.173,
  beta = 0.899,
  lambda = 0.0304,
  phi = 1.42,
  kappa = 2.45,
  phase = 119,
  p_long = 0.775,
  p_silent = 0.245,
  p_RCI = 0.123
)

init_sd = c(alpha = 0.0293,
            beta = 0.0281,
            lambda = 0.0162,
            phi = 0.277,
            kappa = 0.510,
            phase = 6.21,
            p_long = 0.0841,
            p_silent = 0.0599,
            p_RCI = 0.0411)

samp_results = rep(list(NULL), length(data_scenarios)) %>%
  setNames(names(data_scenarios))

max_hours = 4
models = lapply(data_scenarios, make_model)
for (i in seq_len(length(data_scenarios))) {
  print(paste("Scenario", i))
  
  tictoc::tic()
  samp = metropolis_sampling(models[[i]],
                             init = init,
                             init_sd = init_sd,
                             data = data_scenarios[[i]],
                             n_iter = 500,
                             n_burnin = 400,
                             n_adapt = 100,
                             n_chains = n_cores,
                             time_limit = max_hours / length(data_scenarios))
  tictoc::toc()
  samp_results[[i]] = samp
}

# inspect parameter posteriors
posterior_seasonal = lapply(samp_results, function(samp) {
  bind_cols(
    bind_rows(samp$sim),
    bind_rows(samp$sim_diagnostics, .id = "chain")
  ) %>%
    pivot_longer(-c(iteration, accept, lpp, ll, chain), names_to = "parameter", values_to = "value")
}) %>%
  bind_rows(.id = "Scenario") %>%
  mutate(Scenario = fct_inorder(Scenario)) %>%
  left_join(scenarios, by=c("Scenario" = "name")) %>%
  mutate(name_short = name_short %>% str_replace_all(", ", ",\n"))

trace_plot = posterior_seasonal %>%
  ggplot(aes(x = iteration, y = value, color=Scenario, group=interaction(Scenario, chain))) +
  geom_step(alpha=0.25) +
  coord_cartesian(xlim = c(0, NA)) +
  facet_wrap(vars(parameter), scales="free", labeller=plot_labeller_novar) +
  labs(subtitle = "Parameter traces") +
  theme(legend.position = "none")
trace_plot
filename = paste0("../plots/china_trace.png")
ggsave(filename, width=8, height=8)

var_plot = posterior_seasonal %>%
  ggplot(aes(x = value, fill=Scenario, color=Scenario)) +
  geom_density(alpha=0.5) +
  coord_cartesian(xlim = c(0, NA)) +
  facet_wrap(vars(parameter), scales="free", labeller=plot_labeller_novar) +
  labs(subtitle = "Parameter estimates")
var_plot
filename = paste0("../plots/china_variables.png")
ggsave(filename, width=8, height=8)

ll_plot = posterior_seasonal %>%
  ggplot(aes(x = ll, y = name_shortest, color=name_shortest, fill=name_shortest, group=interaction(name_shortest))) +
  ggridges::geom_density_ridges(alpha=0.25) +
  scale_y_discrete(limits = rev) +
  facet_grid(cols=vars(region), scales="free_x") +
  labs(subtitle = "Log likelihood (higher is better)") +
  theme(legend.position = "none")
ll_plot
filename = paste0("../plots/china_loglikelihood.png")
ggsave(filename, width=8, height=8)

lpp_plot = posterior_seasonal %>%
  ggplot(aes(x = lpp, y = name_shortest, color=name_shortest, fill=name_shortest, group=interaction(name_shortest))) +
  ggridges::geom_density_ridges(alpha=0.25) +
  scale_y_discrete(limits = rev) +
  facet_grid(cols=vars(region), scales="free_x") +
  labs(subtitle = "Log posterior probability (higher is better)") +
  theme(legend.position = "none")
lpp_plot
filename = paste0("../plots/china_logposteriorprobability.png")
ggsave(filename, width=8, height=8)

bf_data = posterior_seasonal %>%
  group_by(name_short, name_shortest, n_changes) %>%
  summarise(# lpp = log(sum(exp(lpp))) - log(n()),
    lpp = matrixStats::logSumExp(lpp) - log(n()),
    # ll = mean(ll),
    ll = matrixStats::logSumExp(ll) - log(n()),
    .groups = "drop") %>%
  mutate(baseline_lpp = lpp[name_shortest == "Baseline"],
         baseline_ll = ll[name_shortest == "Baseline"],
         bayes_factor = exp(lpp - baseline_lpp)) %>%
  ungroup() %>%
  filter(name_shortest != "Baseline")

bf_plot = ggplot(bf_data, aes(x = bayes_factor, y = name_shortest, fill = name_shortest)) +
  geom_col(alpha = 0.8) +
  geom_vline(xintercept = 1, linetype="dashed") +
  scale_x_log10(labels = label_auto3, breaks = c(10 ^ c(-14, -7, seq(-2, 3, by=1)))) +
  scale_y_discrete(limits = rev) +
  ggforce::facet_col(vars(n_changes), scales="free_y", space="free") +
  theme(legend.position = "none",
        axis.text.x = element_markdown(angle=-90, hjust=0),
        axis.title.x = element_markdown(),
        strip.background = element_blank(),
        strip.text.x = element_blank(),
        strip.text.y = element_blank()) +
  labs(subtitle = "Bayes factor relative to the baseline model",
       x = "*K*",
       y = NULL)
bf_plot
filename = paste0("../plots/china_bayesfactor.png")
ggsave(filename, width=8, height=4)

# ggsave(filename, width=8, height=4)

# Plot credible intervals
resim = lapply(samp_results, function(samp) {
  resim = extract(samp, "incidence", n_samples=50, threading=T)
}) %>%
  bind_rows(.id = "Scenario") %>%
  mutate(Scenario = fct_inorder(Scenario)) %>%
  left_join(scenarios, by=c("Scenario" = "name")) %>%
  mutate(name_short = name_short %>% str_replace_all(", ", ",\n")) %>%
  pivot_longer(matches("^clinical"), names_to="metric") %>%
  mutate(metric = metric %>% case_match(
    "clinical_incidence" ~ "Total",
    "clinical_relapse" ~ "Relapse",
    "clinical_primary" ~ "Primary"
  ))

plot_original_data = lapply(data_scenarios, function(x) {
  tibble(time = x$ts,
         cases = x$cases)
}) %>%
  bind_rows(.id = "Scenario") %>%
  left_join(scenarios, by=c("Scenario" = "name")) %>%
  mutate(Scenario = fct_inorder(Scenario))

epi_plot = ggplot(mapping = aes(x=time/years)) +
  geom_line(data = resim,
            aes(y=value, color=metric, group=interaction(metric, ix)),
            alpha = 0.1) +
  geom_point(data = plot_original_data,
             aes(y = cases, group = NULL, color=NULL),
             size = 0.5, alpha = 0.5) +
  scale_y_log10(labels = label_auto2) +
  # coord_cartesian(ylim = c(0, NA)) +
  # facet_wrap(vars(Scenario), scales="free_y") +
  facet_grid(rows=vars(name_shortest), cols=vars(region)) +
  labs(x = "Year",
       y = "Monthly incidence",
       color = "Infection type") +
  guides(colour = guide_legend(override.aes = list(alpha = 1)))
epi_plot
filename = paste0("../plots/china_incidence.png")
ggsave(filename, width=8, height=8)

epi_plot / var_plot + theme(legend.position="none") + plot_annotation(tag_levels="A")
filename = paste0("../plots/china_posterior.png")
ggsave(filename, width=8, height=8)

resim_seasonality = pblapply(samp_results[1:2], function(samp) {
  t = seq(0, years, length.out=500)
  samp_sim = bind_rows(samp$sim)
  samp_rand = sample.int(nrow(samp_sim), 500)
  suitability_traces = lapply(samp_rand, function(ix) {
    samp_suitability = tibble(
      time = t,
      suitability = sapply(t, function(tt) {
        omega = suitability(tt, samp$data$eps, samp_sim[[ix, "kappa"]], samp_sim[[ix, "phase"]])
      })
    )
  }) %>%
    bind_rows(.id = "trace")
}) %>%
  bind_rows(.id = "Scenario") %>%
  left_join(scenarios, by=c("Scenario" = "name")) %>%
  mutate(Scenario = fct_inorder(Scenario))

resim_seasonality_plot = resim_seasonality %>%
  filter(scenario <= 2) %>%
  ggplot(aes(x = time, y = suitability, color = region, group = interaction(region, trace))) +
  geom_line(alpha = 0.05) +
  scale_x_continuous(breaks = seq(0, years, length.out=13), labels = c(month.abb, month.abb[1])) +
  labs(subtitle = "Posterior estimates of transmission seasonality",
       x = "Month",
       y = "Mosquito-borne transmission suitability",
       color = "Region") +
  guides(colour = guide_legend(override.aes = list(alpha = 1)))
resim_seasonality_plot
filename = paste0("../plots/china_resim_seasonality_plot.png")
ggsave(filename, width=8, height=4)

rm(trace_plot)
rm(epi_plot)
rm(var_plot)
rm(ll_plot)
rm(lpp_plot)
rm(resim_seasonality_plot)

lapply(samp_results[1:2], function(x) {
  bind_rows(x$sim)
}) %>%
  bind_rows(.id = "Scenario") %>%
  left_join(scenarios, by=c("Scenario" = "name")) %>%
  mutate(Scenario = fct_inorder(Scenario),
         phase = phase + years/4) %>%
  pivot_longer(c(kappa, phase)) %>%
  group_by(Scenario, region, name) %>%
  summarise(mean = mean(value),
            lower = quantile(value, 0.025),
            upper = quantile(value, 0.975),
            .groups = "drop") %>%
  mutate(summary = paste0(signif(mean, 3), " (", signif(lower, 3), ", ", signif(upper, 3), ")")) %>%
  select(region, name, summary)

# Get ranges
var_ranges = posterior_seasonal %>%
  filter(scenario <= 2) %>%
  group_by(parameter) %>%
  summarise(min = min(value),
            max = max(value))
var_priors = list()
baseline_model = models[[1]]
for (i in seq_len(nrow(var_ranges))) {
  parameter_name = var_ranges$parameter[i]
  parameter_min = 0 # var_ranges$min[i]
  parameter_max = var_ranges$max[i]
  parameter_range = parameter_max - parameter_min
  parameter_seq = seq(parameter_min, parameter_max, length.out = 100)
  prior = sapply(parameter_seq, function(x) {
    x_dummy = init
    x_dummy[parameter_name] = x
    exp(baseline_model$log_prior(x_dummy))
  })
  d_prior = prior / mean(prior) / parameter_range
  var_priors[[parameter_name]] = tibble(value = parameter_seq, prior = d_prior)
}
var_priors = bind_rows(var_priors, .id="parameter")
baseline_var_plot = posterior_seasonal %>%
  filter(scenario <= 2) %>%
  ggplot(aes(x = value, fill=region, color=region)) +
  geom_density(alpha=0.5) +
  geom_line(data=var_priors, aes(y=prior, fill=NULL, color=NULL), linetype="dashed") +
  coord_cartesian(xlim = c(0, NA)) +
  facet_wrap(vars(parameter), scales="free", labeller=plot_labeller_novar) +
  labs(subtitle = "Posterior parameter estimates",
       x = NULL,
       y = NULL,
       color = "Region",
       fill = "Region")
baseline_var_plot
filename = paste0("../plots/china_baseline_variables.png")
ggsave(filename, width=8, height=8)

baseline_epi_plot = resim %>%
  filter(scenario <= 2) %>%
  mutate(metric = metric %>% case_match(
    "clinical_incidence" ~ "Total",
    "clinical_relapse" ~ "Relapse",
    "clinical_primary" ~ "Primary"
  )) %>%
  ggplot(aes(x=time/years)) +
  geom_line(aes(y=value, color=metric, group=interaction(metric, ix)),
            alpha = 0.1) +
  geom_point(data = plot_original_data,
             aes(y = cases, group = NULL, color=NULL),
             size = 0.5, alpha = 0.5) +
  scale_y_log10(labels = label_auto2) +
  # coord_cartesian(ylim = c(0, NA)) +
  # facet_wrap(vars(Scenario), scales="free_y") +
  facet_grid(cols=vars(region)) +
  labs(x = "Year",
       y = "Monthly incidence",
       color = "Infection type",
       subtitle = "Modelled mean incidence") +
  guides(colour = guide_legend(override.aes = list(alpha = 1)))
baseline_epi_plot
filename = paste0("../plots/china_baseline_epi.png")
ggsave(filename, width=8, height=8)

baseline_var_plot / baseline_epi_plot +
  plot_layout(heights = c(2, 1)) +
  plot_annotation(tag_levels = "A")
filename = paste0("../plots/china_baseline.png")
ggsave(filename, width=8, height=8)

rm(baseline_var_plot)
rm(baseline_epi_plot)

accept = lapply(samp_results, function(x) {
  mean(unlist(x$accept))
})

ess = lapply(samp_results, function(x) {
  x$ESS %>% unlist %>% matrix(ncol=9, byrow=T) %>% colSums() %>% setNames(names(x$current_x[[1]]))
})

end_time = Sys.time()
print(end_time)
print(end_time - start_time)
workspace_filename = paste0("workspaces/Chapter_02_china_metropolis_", Sys.Date(), ".RData")
# save.image(workspace_filename)

mean_posterior_seasonal = posterior_seasonal %>%
  group_by(parameter) %>%
  summarise(median = median(value)) %>%
  mutate(parameter = fct_relevel(parameter, names(init))) %>%
  arrange(parameter)

sd_posterior_seasonal = posterior_seasonal %>%
  group_by(parameter, scenario) %>%
  summarise(sd = sd(value)) %>%
  summarise(med_sd = median(sd)) %>%
  mutate(parameter = fct_relevel(parameter, names(init))) %>%
  arrange(parameter)