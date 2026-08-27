resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# ---------------------------------------------------------------------------
# Subnets — public holds ONLY the ALB and the bastion.
# Web and database tiers live in private subnets with no route to the IGW.
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public-${var.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-private-${var.azs[count.index]}" }
}

# ---------------------------------------------------------------------------
# Public routing
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-public-rt" }
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# NAT — ONE PER AZ, not one shared gateway.
#
# A single shared NAT would quietly undermine the whole point of multi-AZ:
# losing the AZ that holds it removes outbound connectivity for the surviving
# zone too. Each private subnet therefore egresses through the NAT in its OWN
# availability zone.
#
# `count` is driven by var.nat_enabled purely for overnight cost control.
# NAT gateways are stateless, so tearing them down and rebuilding loses nothing.
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count  = var.nat_enabled ? 2 : 0
  domain = "vpc"

  tags = { Name = "${var.project}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "main" {
  count         = var.nat_enabled ? 2 : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]

  tags = { Name = "${var.project}-nat-${var.azs[count.index]}" }
}

# The route tables themselves always exist — only the default route through NAT
# comes and goes. That keeps subnet associations stable across the nightly flag.
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-private-rt-${var.azs[count.index]}" }
}

resource "aws_route" "private_nat" {
  count                  = var.nat_enabled ? 2 : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
