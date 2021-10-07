provider "aws" {
  profile = "default"
  region  = var.region
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "rdmx-vpc"
  cidr = "10.0.0.0/16"

  azs = ["us-east-2a", "us-east-2b"]

  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24", "10.0.5.0/24"]

  enable_vpn_gateway = true

  enable_nat_gateway      = true
  single_nat_gateway      = false
  one_nat_gateway_per_az  = true
  map_public_ip_on_launch = true
  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "loadbalancer_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "rdmx-lb-sg"
  description = "Security group for loadbalancer."
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      rule        = "http-80-tcp"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "application_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "rdmx-app-sg"
  description = "Security group for application-level instances."
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "http-80-tcp"
      source_security_group_id = module.loadbalancer_security_group.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1
  ingress_with_cidr_blocks = [
    {
      rule        = "ssh-tcp"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "db_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "rdmx-db-sg"
  description = "Security group for database-level instances."
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "mysql-tcp"
      source_security_group_id = module.application_security_group.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1


  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "rdmx-alb"

  load_balancer_type = "application"

  vpc_id          = module.vpc.vpc_id
  subnets         = [module.vpc.public_subnets[0], module.vpc.public_subnets[1]]
  security_groups = [module.loadbalancer_security_group.security_group_id]

  target_groups = [
    {
      name_prefix      = "rdmx-"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "instance"
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  tags = {
    Environment = "Test"
  }
}
resource "aws_launch_template" "rdmx-lt" {
  name = "rdmx-lt"
  image_id = var.ami
  instance_type = "t2.micro"
  monitoring {
    enabled = true
  }

  network_interfaces {
    associate_public_ip_address = true
    
    security_groups = [module.application_security_group.security_group_id]
  }
  placement {
    availability_zone = "us-east-2a"
  }
  #vpc_security_group_ids = [module.application_security_group.security_group_id]
}

resource "aws_autoscaling_group" "rdmx-asg" {
  desired_capacity   = 2
  max_size           = 4
  min_size           = 2
  vpc_zone_identifier = [module.vpc.private_subnets[0], module.vpc.private_subnets[1]]
  target_group_arns = module.alb.target_group_arns
  launch_template {
    id      = aws_launch_template.rdmx-lt.id
    version = "$Latest"
  }
}
resource "aws_sns_topic" "user_updates" {
  name = "rdmx-updates-topic"
}

module "metric_alarm_scale_out" {
  source              = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version             = "~> 2.0"
  alarm_name          = "rdmx-scale-out"
  alarm_description   = "Autoscaling alarm when Scaling-Out"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 70
  period              = 60
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.rdmx-asg.name
  }

  alarm_actions = [aws_sns_topic.user_updates.arn, aws_autoscaling_policy.scale-out.arn]
}
module "metric_alarm_scale_in" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version = "~> 2.0"

  alarm_name          = "rdmx-scale-in"
  alarm_description   = "Autoscaling alarm when Scaling-In"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 20
  period              = 60

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.rdmx-asg.name
  }
  alarm_actions = [aws_sns_topic.user_updates.arn, aws_autoscaling_policy.scale-in.arn]
}
resource "aws_sns_topic_subscription" "user_updates_sqs_target" {
  topic_arn = aws_sns_topic.user_updates.arn
  protocol  = "email"
  endpoint  = var.subcriptions_email1
}
resource "aws_sns_topic_subscription" "user_updates_sqs_target2" {
  topic_arn = aws_sns_topic.user_updates.arn
  protocol  = "email"
  endpoint  = var.subcriptions_email2
}
resource "aws_sns_topic_subscription" "user_updates_sqs_target3" {
  topic_arn = aws_sns_topic.user_updates.arn
  protocol  = "email"
  endpoint  = var.subcriptions_email3
}
resource "aws_autoscaling_policy" "scale-in" {
  name                   = "scale-in-policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.rdmx-asg.name
}

resource "aws_autoscaling_policy" "scale-out" {
  name                   = "scale-out-policy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.rdmx-asg.name
}

resource "aws_route53_record" "www" {
  zone_id = var.hosted_zone_id
  name    = var.hosted_zone
  type    = "A"

  alias {
    name                   = module.alb.lb_dns_name
    zone_id                = module.alb.lb_zone_id
    evaluate_target_health = true
  }
}

