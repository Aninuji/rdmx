provider "aws"{
    profile = "default"
    region  =  "us-east-2"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "rdmx-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-2a", "us-east-2b"]

  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24", "10.0.5.0/24"]

  enable_vpn_gateway = true

  enable_nat_gateway = true
  single_nat_gateway = false
  one_nat_gateway_per_az = true
  map_public_ip_on_launch = true
  tags = {
    Terraform = "true"
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
    Terraform = "true"
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
      rule        = "http-80-tcp"
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
    Terraform = "true"
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
      rule        = "mysql-tcp"
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
    Terraform = "true"
    Environment = "dev"
  }
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "rdmx-alb"

  load_balancer_type = "application"

  vpc_id             = module.vpc.vpc_id
  subnets            = [module.vpc.public_subnets[0], module.vpc.public_subnets[1]]
  security_groups    = [module.loadbalancer_security_group.security_group_id]

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

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 4.0"

  # Autoscaling group
  name = "rdmx-asg"

  min_size                  = 2
  max_size                  = 4
  desired_capacity          = 3
  wait_for_capacity_timeout = 0
  health_check_type         = "EC2"
  vpc_zone_identifier       = [module.vpc.private_subnets[0] , module.vpc.private_subnets[1]]

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 50
    }
    triggers = ["tag"]
  }

  target_group_arns=module.alb.target_group_arns

  # Launch template
  use_lt    = true
  launch_template = "demo-template"  

  enable_monitoring = true
  enabled_metrics = ["GroupDesiredCapacity"]

}
resource "aws_sns_topic" "user_updates" {
  name = "rdmx-updates-topic"
}

module "metric_alarm_scale_out" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version = "~> 2.0"

  alarm_name          = "rdmx-scale-out"
  alarm_description   = "Autoscaling alarm when Scaling-Out"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 70
  period              = 60
  unit                = "Count"

  namespace   = "MyApplication"
  metric_name = "CPU Maxout"
  statistic   = "Maximum"

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
  unit                = "Count"

  namespace   = "MyApplication"
  metric_name = "CPU Minimum"
  statistic   = "Minimum"

  alarm_actions = [aws_sns_topic.user_updates.arn, aws_autoscaling_policy.scale-in.arn]
}

resource "aws_sns_topic_subscription" "user_updates_sqs_target" {
  topic_arn = aws_sns_topic.user_updates.arn
  protocol  = "email"
  endpoint  = "mariost1995@hotmail.com"
}



resource "aws_autoscaling_policy" "scale-in" {
  name                   = "scale-in-policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = module.asg.autoscaling_group_name
  
}

resource "aws_autoscaling_policy" "scale-out" {
  name                   = "scale-out-policy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = module.asg.autoscaling_group_name
}