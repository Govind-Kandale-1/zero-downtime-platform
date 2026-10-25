variable "name" {
  description = "kind cluster name."
  type        = string
  default     = "zdp"
}

variable "node_image" {
  description = "kindest/node image, pinned by digest (config/versions.env KIND_NODE_IMAGE)."
  type        = string
}

variable "workers" {
  description = "Number of worker nodes. Two lets PDBs, topology spread and drains be demonstrated."
  type        = number
  default     = 2
}

variable "kubeconfig_path" {
  description = "Where to write the kubeconfig."
  type        = string
}
