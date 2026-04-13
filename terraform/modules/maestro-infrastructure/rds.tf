# =============================================================================
# RDS PostgreSQL Database for Maestro Server
#
# Stores Maestro Server state including consumer registrations and
# ManifestWork resources
# =============================================================================

# Generate secure random password for database
# TODO: Will go once using ASCP for access
resource "random_password" "db_password" {
  length  = 32
  special = true
  # Exclude characters that might cause issues in connection strings
  override_special = "!#$%&*()-_=+[]{}:?"
}

# DB Subnet Group spanning multiple AZs
resource "aws_db_subnet_group" "maestro" {
  name       = "${var.regional_id}-maestro-db"
  subnet_ids = var.private_subnets

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-maestro-db-subnet-group"
      Component = "maestro-server"
    }
  )
}

# Security Group for RDS
# Ingress rules are standalone resources so the SG (and RDS) can provision
# in parallel with EKS, rather than waiting for EKS security group IDs.
resource "aws_security_group" "maestro_db" {
  name        = "${var.regional_id}-maestro-db"
  description = "Security group for Maestro PostgreSQL database"
  vpc_id      = var.vpc_id

  # Prevent Terraform from trying to detach RDS-managed ENIs
  revoke_rules_on_delete = false

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-maestro-db-sg"
      Component = "maestro-server"
    }
  )
}

# Ingress rules as standalone resources — these depend on EKS SG IDs but
# do NOT block the RDS instance from provisioning.

resource "aws_security_group_rule" "maestro_db_eks_cluster" {
  type                     = "ingress"
  description              = "PostgreSQL from EKS cluster additional security group"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.maestro_db.id
  source_security_group_id = var.eks_cluster_security_group_id
}

resource "aws_security_group_rule" "maestro_db_eks_primary" {
  type                     = "ingress"
  description              = "PostgreSQL from EKS cluster primary security group (Auto Mode)"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.maestro_db.id
  source_security_group_id = var.eks_cluster_primary_security_group_id
}

resource "aws_security_group_rule" "maestro_db_bastion" {
  count = var.bastion_enabled ? 1 : 0

  type                     = "ingress"
  description              = "PostgreSQL from bastion"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.maestro_db.id
  source_security_group_id = var.bastion_security_group_id
}

# RDS PostgreSQL Instance
resource "aws_db_instance" "maestro" {
  identifier = "${var.regional_id}-maestro"

  # Engine configuration
  engine         = "postgres"
  engine_version = var.db_engine_version

  # Instance configuration
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  # TODO: Move this into a policy
  # Database configuration
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result
  port     = 5432

  # Network configuration
  db_subnet_group_name   = aws_db_subnet_group.maestro.name
  vpc_security_group_ids = [aws_security_group.maestro_db.id]
  publicly_accessible    = false

  # High availability
  multi_az = var.db_multi_az

  # Backup configuration
  backup_retention_period = var.db_backup_retention_period
  backup_window           = "03:00-04:00"         # 3-4 AM UTC
  maintenance_window      = "mon:04:00-mon:05:00" # Monday 4-5 AM UTC

  # Snapshot configuration
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_deletion_protection ? "${var.regional_id}-maestro-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null
  deletion_protection       = var.db_deletion_protection

  # Monitoring and logging
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  performance_insights_enabled          = true
  performance_insights_retention_period = 7 # days

  # Auto minor version upgrades
  auto_minor_version_upgrade = true

  # Parameter group (use default for now, can customize later)
  parameter_group_name = "default.postgres18"

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-maestro-db"
      Component = "maestro-server"
    }
  )

  # Prevent replacement due to timestamp in final_snapshot_identifier
  # Also ensure RDS instance is deleted before security group cleanup
  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }

  depends_on = [aws_security_group.maestro_db]
}
