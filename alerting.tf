# ---------------------------------------------------------------------------
# Alert delivery: Prometheus -> Alertmanager (on the monitoring instance)
# -> SNS -> email. Set var.alert_email to receive alerts; the subscription
# must be confirmed once from the email AWS sends.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  count = var.enable_monitoring ? 1 : 0

  name = "${var.project_name}-${var.environment}-alerts"

  tags = {
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.enable_monitoring && var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Alertmanager publishes with the instance role credentials (sigv4)
data "aws_iam_policy_document" "monitoring_alerts" {
  count = var.enable_monitoring ? 1 : 0

  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts[0].arn]
  }

  # The setup script stores the generated Grafana admin password at
  # <ssm_prefix>/monitoring/grafana_admin_password for retrieval without SSH
  statement {
    sid       = "StoreGrafanaPassword"
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/monitoring/*"]
  }
}

resource "aws_iam_role_policy" "monitoring_alerts" {
  count = var.enable_monitoring ? 1 : 0

  name_prefix = "alerts-and-ssm-"
  role        = aws_iam_role.monitoring[0].id
  policy      = data.aws_iam_policy_document.monitoring_alerts[0].json
}
