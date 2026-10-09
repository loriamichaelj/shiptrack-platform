# The SSM contract (design §6.9): every platform output the legacy and modern repositories read,
# written as Standard-tier parameters under var.path_prefix. Those repositories never read this
# repository's Terraform state. Removing or renaming a key is a breaking change that needs an ADR and
# coordinated pull requests.

locals {
  # Lists are published as comma-separated StringList parameters; everything else as a String. join()
  # rejects a string, which is how a scalar is told from a list.
  parameters = {
    for key, value in var.contract :
    key => {
      type  = can(join(",", value)) ? "StringList" : "String"
      value = try(join(",", value), tostring(value))
    }
  }
}

resource "aws_ssm_parameter" "contract" {
  #checkov:skip=CKV2_AWS_34: the contract holds identifiers and ARNs, never secret values, so the parameters are plain String and StringList (design §6.9)
  for_each = local.parameters

  name  = "${var.path_prefix}/${each.key}"
  type  = each.value.type
  value = each.value.value
  tier  = "Standard"
}
