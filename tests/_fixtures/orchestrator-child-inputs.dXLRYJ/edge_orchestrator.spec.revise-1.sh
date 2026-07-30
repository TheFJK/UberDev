SPEC_REVISE_INPUTS="$(uberdev_child_inputs_build orchestrator.spec.revise \
  spec_path "$(uberdev_design_json_string "$spec_path")" \
  revision_path "$(uberdev_design_json_string "$revision_brief_path")" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")")"
for revision_cycle in 1 2; do
  revise_instance="orchestrator-spec-revise-r${revision_cycle}-a1"
  uberdev_design_dispatch orchestrator.spec.revise "$revise_instance" spec-reviser spec run 'null' "$SPEC_REVISE_INPUTS"
  uberdev_design_wait "$revise_instance" 600
  if [ "${spec_reviser_format_invalid:-0}" = 1 ]; then
    revise_retry_instance="orchestrator-spec-revise-r${revision_cycle}-a2"
    SPEC_REVISE_FORMAT_INPUTS="$(uberdev_child_inputs_format_retry orchestrator.spec.revise "$SPEC_REVISE_INPUTS" "$spec_reviser_format_example_path")"
    uberdev_design_dispatch orchestrator.spec.revise "$revise_retry_instance" spec-reviser spec run 'null' "$SPEC_REVISE_FORMAT_INPUTS"
    uberdev_design_wait "$revise_retry_instance" 600
  fi

  # Run the four spec artifact checks above before this re-review.
  SPEC_REREVIEW_INPUTS="$(uberdev_child_inputs_build orchestrator.spec.review \
    spec_path "$(uberdev_design_json_string "$spec_path")" \
    issue_path "$(uberdev_design_json_string "$issue_body_path")" \
    research_paths "$research_paths_json" \
    working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")")"
  review_instance="orchestrator-spec-review-r${revision_cycle}-a1"
  uberdev_design_dispatch orchestrator.spec.review "$review_instance" spec-reviewer spec run 'null' "$SPEC_REREVIEW_INPUTS"
  uberdev_design_wait "$review_instance" 600
  if [ "${spec_reviewer_format_invalid:-0}" = 1 ]; then
    review_retry_instance="orchestrator-spec-review-r${revision_cycle}-a2"
    SPEC_REREVIEW_FORMAT_INPUTS="$(uberdev_child_inputs_format_retry orchestrator.spec.review "$SPEC_REREVIEW_INPUTS" "$spec_review_format_example_path")"
    uberdev_design_dispatch orchestrator.spec.review "$review_retry_instance" spec-reviewer spec run 'null' "$SPEC_REREVIEW_FORMAT_INPUTS"
    uberdev_design_wait "$review_retry_instance" 600
  fi
  [ "$spec_review_verdict" = REVISIONS_REQUIRED ] || break
done
