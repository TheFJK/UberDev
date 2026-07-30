GENERAL_PRIOR_ART_INPUTS="$(uberdev_child_inputs_build orchestrator.research.prior_art \
  issue_path "$(uberdev_design_json_string "$issue_body_path")" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")" \
  summary_path "$(uberdev_design_json_string "$research_prior_art_summary_path")")"
uberdev_design_dispatch orchestrator.research.prior_art orchestrator-research-prior-art-a1 research-prior-art research none '[]' "$GENERAL_PRIOR_ART_INPUTS"
