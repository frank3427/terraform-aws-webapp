resource "aws_lb" "main" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = var.alb_deletion_protection

  # Reject requests with malformed headers (request-smuggling defense)
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb-logs"
    enabled = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-alb"
    Environment = var.environment
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_target_group" "web" {
  name     = "${var.project_name}-${var.environment}-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # Default drain time is 300s, which stalls every instance replacement
  # for 5 minutes. These are short HTTP requests; 60s is ample.
  deregistration_delay = 60

  # /healthz is served from each instance's local disk (see healthz.conf in
  # web_server_setup.sh). Probing a path that lives on EFS would fail health
  # checks on EVERY instance at once during an EFS stall and take the whole
  # fleet out of service; this probe tests only Apache itself.
  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/healthz"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  # PHP stores sessions on local disk by default, so a client must keep
  # landing on the same server or logins/carts break. Duration-based
  # cookie stickiness pins each client to one healthy instance.
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-web-tg"
    Environment = var.environment
  }
}

# Web instances are registered with the target group by the Auto Scaling
# Group (target_group_arns in ec2.tf); no static attachments needed.

resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  # When an ACM certificate is configured, HTTP redirects to HTTPS.
  # Otherwise HTTP forwards straight to the web servers.
  default_action {
    type             = var.acm_certificate_arn == "" ? "forward" : "redirect"
    target_group_arn = var.acm_certificate_arn == "" ? aws_lb_target_group.web.arn : null

    dynamic "redirect" {
      for_each = var.acm_certificate_arn == "" ? [] : [1]
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-web-listener"
    Environment = var.environment
  }
}

# HTTPS termination at the ALB using an ACM certificate.
# Traffic to the web servers stays plain HTTP on port 80; instances never
# handle TLS. Apps can detect the original scheme via X-Forwarded-Proto.
resource "aws_lb_listener" "https" {
  count = var.acm_certificate_arn == "" ? 0 : 1

  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-https-listener"
    Environment = var.environment
  }
}