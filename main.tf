provider "aws" {
  region = "${var.region}"
  profile = "${var.profile}"
}

resource "aws_vpc" "vpc_main" {
  cidr_block = "10.0.0.0/16"
  
  enable_dns_support = true
  enable_dns_hostnames = true
  
  tags {
    Name = "Main VPC"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.vpc_main.id}"
}

resource "aws_route_table" "custom" {
    vpc_id = "${aws_vpc.vpc_main.id}"
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = "${aws_internet_gateway.gw.id}"
    }

    tags {
        Name = "Route_Table"
    }
}

# Create a public subnet to launch our load balancers
resource "aws_subnet" "public" {
  vpc_id                  = "${aws_vpc.vpc_main.id}"
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

# Create a private subnet to launch our backend instances
resource "aws_subnet" "private" {
  vpc_id                  = "${aws_vpc.vpc_main.id}"
  cidr_block              = "10.0.2.0/24" 
  map_public_ip_on_launch = true
}

resource "aws_route_table_association" "association" {
  subnet_id      = "${aws_subnet.public.id}"
  route_table_id = "${aws_route_table.custom.id}"
}

# A security group for the ELB so it is accessible via the web
resource "aws_security_group" "elb" {
  name        = "sec_group_elb"
  description = "Security group for public facing ELBs"
  vpc_id      = "${aws_vpc.vpc_main.id}"

  # HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  # HTTPS access from anywhere
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Our default security group to access the instances over SSH and HTTP
resource "aws_security_group" "default" {
  name        = "sec_group_private"
  description = "Security group for backend servers and private ELBs"
  vpc_id      = "${aws_vpc.vpc_main.id}"

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # HTTP access from the VPC
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
} 
 # Outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "auth" {
  key_name   = "${var.key_name}"
  public_key = "${file(var.public_key_path)}"
}

resource "aws_launch_configuration" "agent-lc" {
    name_prefix = "agent-lc-"
    image_id = "ami-66506c1c"
    instance_type = "t2.micro"
    key_name = "${aws_key_pair.auth.id}"
    security_groups = ["${aws_security_group.default.id}"]
    user_data = <<-EOF
                #!/bin/bash
                echo "Hello, I am Sandeep" >index.html
                nohup busybox httpd -f -p 80 &
                EOF
    lifecycle {
        create_before_destroy = true
    }

    root_block_device {
        volume_type = "gp2"
        volume_size = "50"
    }
}

resource "aws_autoscaling_group" "agents" {
    availability_zones = ["us-east-1a"]
    name = "agents"
    max_size = "5"
    min_size = "3"
    health_check_grace_period = 300
    health_check_type = "EC2"
    desired_capacity = 4
    force_delete = true
    launch_configuration = "${aws_launch_configuration.agent-lc.name}"

    tag {
        key = "Name"
        value = "Agent Instance"
        propagate_at_launch = true
    }
}

resource "aws_autoscaling_policy" "agents-scale-up" {
    name = "agents-scale-up"
    scaling_adjustment = 1
    adjustment_type = "ChangeInCapacity"
    cooldown = 300
    autoscaling_group_name = "${aws_autoscaling_group.agents.name}"
}

resource "aws_autoscaling_policy" "agents-scale-down" {
    name = "agents-scale-down"
    scaling_adjustment = -1
    adjustment_type = "ChangeInCapacity"
    cooldown = 300
    autoscaling_group_name = "${aws_autoscaling_group.agents.name}"
}

resource "aws_cloudwatch_metric_alarm" "cpu-high" {
    alarm_name = "cpu-util-high-agents"
    comparison_operator = "GreaterThanOrEqualToThreshold"
    evaluation_periods = "2"
    metric_name = "CPUUtilization"
    namespace = "AWS/EC2"
    period = "300"
    statistic = "Average"
    threshold = "80"
    alarm_description = "This metric monitors ec2 CPU for high utilization on agent hosts"
    alarm_actions = [
        "${aws_autoscaling_policy.agents-scale-up.arn}"
    ]
    dimensions {
        AutoScalingGroupName = "${aws_autoscaling_group.agents.name}"
    }
}

resource "aws_cloudwatch_metric_alarm" "CPU-low" {
    alarm_name = "CPU-util-low-agents"
    comparison_operator = "LessThanOrEqualToThreshold"
    evaluation_periods = "2"
    metric_name = "CPUUtilization"
    namespace = "AWS/EC2"
    period = "300"
    statistic = "Average"
    threshold = "40"
    alarm_description = "This metric monitors ec2 CPU for low utilization on agent hosts"
    alarm_actions = [
        "${aws_autoscaling_policy.agents-scale-down.arn}"
    ]
    dimensions {
        AutoScalingGroupName = "${aws_autoscaling_group.agents.name}"
    }
}

resource "aws_elb" "load" {
  name               = "terraform-elb"
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]


  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 30
  }

  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400
  security_groups = ["${aws_security_group.elb.id}"]
  tags {
    Name = "terraform-elb"
  }
}

resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = "${aws_autoscaling_group.agents.id}"
  elb                    = "${aws_elb.load.id}"
}
