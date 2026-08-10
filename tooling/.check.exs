[
  ## don't run tools concurrently
  # parallel: false,

  ## don't print info about skipped tools
  skipped: false,

  ## always run tools in fix mode (put it in ~/.check.exs locally, not in project config)
  fix: true,

  ## don't retry automatically even if last run resulted in failures
  retry: false,

  ## list of tools (see `mix check` docs for a list of default curated tools)
  tools: [
    {:compiler, env: %{"MIX_ENV" => "test"}},
    {:formatter, env: %{"MIX_ENV" => "test"}},
    # Overrides ex_check's built-in `mix_audit` tool (a bare `mix deps.audit`
    # would otherwise run too). The four ignored advisories are all hackney,
    # with no patched release below 4.0.1 (a major that doesn't exist yet) —
    # tzdata pins hackney to ~> 1.17, so they're unfixable by upgrade today.
    # Tracked in https://github.com/advisories/GHSA-gp9c-pm5m-5cxr.
    {:mix_audit,
     "mix deps.audit --ignore-advisory-ids GHSA-mp55-p8c9-rfw2,GHSA-pj7v-xfvx-wmjq,GHSA-j9wq-vxxc-94wf,GHSA-gp9c-pm5m-5cxr"},
    {:sobelow, "mix sobelow --config"},
    {:prettier_formatting, "yarn run lint:check", fix: "yarn run lint:fix"},
    {:npm_test, false},
    {:gettext, false},
    {:ex_unit, env: %{"MIX_ENV" => "test", "EX_CHECK" => "1"}}

    ## curated tools may be disabled (e.g. the check for compilation warnings)
    # {:compiler, false},

    ## ...or have command & args adjusted (e.g. enable skip comments for sobelow)
    # {:sobelow, "mix sobelow --exit --skip"},

    ## ...or reordered (e.g. to see output from dialyzer before others)
    # {:dialyzer, order: -1},

    ## ...or reconfigured (e.g. disable parallel execution of ex_unit in umbrella)
    # {:ex_unit, umbrella: [parallel: false]},

    ## custom new tools may be added (Mix tasks or arbitrary commands)
    # {:my_task, "mix my_task", env: %{"MIX_ENV" => "prod"}},
    # {:my_tool, ["my_tool", "arg with spaces"]}
  ]
]
