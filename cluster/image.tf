# Vanilla Rocky 9 (when NOT using golden image)
resource "harvester_image" "rocky9" {
  count              = var.use_golden_image ? 0 : 1
  name               = "${var.cluster_name}-rocky9"
  namespace          = var.vm_namespace
  display_name       = "${var.cluster_name}-rocky9"
  source_type        = "download"
  url                = var.rocky_image_url
  storage_class_name = "harvester-longhorn"

  timeouts {
    create = "30m"
  }
}

# Golden image lookup (when using golden image)
data "harvester_image" "golden" {
  count     = var.use_golden_image ? 1 : 0
  name      = var.golden_image_name
  namespace = var.vm_namespace

  lifecycle {
    precondition {
      condition     = var.golden_image_name != ""
      error_message = "golden_image_name is required when use_golden_image is true."
    }
  }
}
