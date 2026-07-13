terraform {
  backend "s3" {}

  required_providers {
    pagerduty = {
      source  = "PagerDuty/pagerduty"
      version = ">= 3.0"
    }
  }
}
