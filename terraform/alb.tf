resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false

  # Reject requests with malformed headers instead of forwarding them to the
  # application to interpret. Cheap defence against request-smuggling tricks.
  drop_invalid_header_fields = true

  tags = { Name = "${var.project}-alb" }
}

resource "aws_lb_target_group" "web" {
  name     = "${var.project}-web-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/healthz" # a real endpoint, not "/"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  # Short, so a failover drill produces a measurable gap rather than a five
  # minute wait. Raise this for a real production workload with long requests.
  deregistration_delay = 15

  tags = { Name = "${var.project}-web-tg" }
}

resource "aws_lb_target_group_attachment" "web" {
  count            = 2
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web[count.index].id
  port             = 8080
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# No port 80 listener exists on purpose. The ALB security group only admits 443
# from Cloudflare, and Cloudflare handles the HTTP-to-HTTPS redirect at the edge.
