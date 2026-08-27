# `http_tokens = "required"` enforces IMDSv2 on every instance. It is one line
# and it closes the SSRF-to-credential-theft path behind the Capital One breach.
# Interviewers notice when it is missing.

resource "aws_instance" "bastion" {
  ami                         = local.ubuntu_ami
  instance_type               = var.instance_type_bastion
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = {
    Name = "${var.project}-bastion"
    Role = "bastion"
  }
}

resource "aws_instance" "web" {
  count                       = 2
  ami                         = local.ubuntu_ami
  instance_type               = var.instance_type_web
  subnet_id                   = aws_subnet.private[count.index].id
  vpc_security_group_ids      = [aws_security_group.web.id]
  key_name                    = var.key_name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  tags = {
    Name = "${var.project}-web-${count.index + 1}"
    Role = "web"
    AZ   = var.azs[count.index]
  }
}

resource "aws_instance" "db_primary" {
  ami                         = local.ubuntu_ami
  instance_type               = var.instance_type_db
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.db.id]
  key_name                    = var.key_name
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.db.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 30
  }

  tags = {
    Name = "${var.project}-db-primary"
    Role = "db_primary"
    AZ   = var.azs[0]
  }
}

resource "aws_instance" "db_replica" {
  ami                         = local.ubuntu_ami
  instance_type               = var.instance_type_db
  subnet_id                   = aws_subnet.private[1].id
  vpc_security_group_ids      = [aws_security_group.db.id]
  key_name                    = var.key_name
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.db.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 30
  }

  tags = {
    Name = "${var.project}-db-replica"
    Role = "db_replica"
    AZ   = var.azs[1]
  }
}
