FOLLOWUP_FORMAT_INPUTS="$(uberdev_child_inputs_format_retry orchestrator.research.followup "$FOLLOWUP_INPUTS" "$followup_format_example_path")"
uberdev_design_dispatch orchestrator.research.followup orchestrator-research-followup-a2 research-codebase research none '[]' "$FOLLOWUP_FORMAT_INPUTS"
uberdev_design_wait orchestrator-research-followup-a2 300
