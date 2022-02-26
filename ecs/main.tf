locals {
  name = "bombardier"
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name

  cidr = "10.1.0.0/16"

  azs             = [data.aws_availability_zones.available.names[0], data.aws_availability_zones.available.names[1]]
  private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
  public_subnets  = ["10.1.11.0/24", "10.1.12.0/24"]

  enable_nat_gateway = false # false is just faster

  tags = {
    Name        = local.name
  }
}

#----- ECS --------
module "ecs" {
  source = "terraform-aws-modules/ecs/aws"

  name               = local.name
  container_insights = true

  capacity_providers = ["FARGATE", "FARGATE_SPOT", aws_ecs_capacity_provider.prov1.name]

  default_capacity_provider_strategy = [{
    capacity_provider = aws_ecs_capacity_provider.prov1.name
    weight            = "1"
  }]
}

module "ec2_profile" {
  source = "terraform-aws-modules/ecs/aws/modules/ecs-instance-profile"

  name = local.name
}

resource "aws_ecs_capacity_provider" "prov1" {
  name = "prov1"

  auto_scaling_group_provider {
    auto_scaling_group_arn = module.asg.autoscaling_group_arn
  }

}

#----- ECS  Services--------
module "bombardier" {
  source = "./bombardier"

  cluster_id = module.ecs.ecs_cluster_id
}

#----- ECS  Resources--------

data "aws_ami" "amazon_linux_ecs" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-*-amazon-ecs-optimized"]
  }

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }
}

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"

  name = local.name

  # Launch configuration
  lc_name   = local.name
  use_lc    = true
  create_lc = true

  image_id                  = data.aws_ami.amazon_linux_ecs.id
  instance_type             = "t2.micro"
  security_groups           = [module.vpc.default_security_group_id]
  iam_instance_profile_name = module.ec2_profile.iam_instance_profile_id
  user_data = templatefile("${path.module}/templates/user-data.sh", {
    cluster_name = local.name
  })

  # Auto scaling group
  vpc_zone_identifier       = module.vpc.private_subnets
  health_check_type         = "EC2"
  min_size                  = 0
  max_size                  = vars.desired_capacity
  desired_capacity          = vars.desired_capacity
  wait_for_capacity_timeout = 0

  instance_market_options = {
    market_type = "spot"
    spot_options = {
      block_duration_minutes = 60
    }
  }

  tags = [
    {
      key                 = "Cluster"
      value               = local.name
      propagate_at_launch = true
    },
  ]
}
