FORMAT_RETRY_INPUTS="$(uberdev_child_inputs_format_retry "$failed_edge" "$failed_inputs_json" "$format_example_path")"
format_retry_instance="${failed_instance%-a1}-a2"
uberdev_design_dispatch "$failed_edge" "$format_retry_instance" "$failed_role" "$failed_phase" none "$failed_risks_json" "$FORMAT_RETRY_INPUTS"
uberdev_design_wait "$format_retry_instance" 300
