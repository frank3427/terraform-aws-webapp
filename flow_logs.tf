# ---------------------------------------------------------------------------
# VPC Flow Logs: network-level audit trail for incident investigation and
# anomaly detection. Required by most compliance regimes for systems that
# handle transactional data.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/vpc/${var.project_name}-${var.environment}/flow-logs"
  retention_in_days = 90

  tags = {
    Environment = var.environment
  }
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name_prefix        = "${var.project_name}-${var.environment}-flowlogs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json

  tags = {
    Environment = var.environment
  }
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name_prefix = "flow-logs-"
  role        = aws_iam_role.flow_logs.id
  policy      = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = {
    Name        = "${var.project_name}-${var.environment}-flow-logs"
    Environment = var.environment
  }
}
