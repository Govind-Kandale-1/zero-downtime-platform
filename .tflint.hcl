# tflint for every Terraform root and module (run with --recursive).
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
