########################################
# VPC 및 인터넷 게이트웨이 생성
########################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.vpc_tag_name
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = var.igw_tag_name
  }
}

########################################
# 퍼블릭 서브넷 생성 및 NAT 게이트웨이 구성
########################################

# 퍼블릭 서브넷 생성 (동적 count 사용)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index].cidr
  availability_zone       = var.public_subnets[count.index].az
  map_public_ip_on_launch = true

  tags = {
    Name = "Public-${var.env}-${var.public_subnets[count.index].az}"
  }
}

# NAT Elastic IP (단일)
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = var.eip_nat_tag_name
  }

  depends_on = [aws_vpc.main]
}

# NAT 게이트웨이 (퍼블릭 서브넷 1개에만 생성)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id  # 첫 번째 퍼블릭 서브넷에 NAT 생성

  tags = {
    Name = var.nat_gateway_tag_name
  }

  depends_on = [aws_eip.nat]
}

# 퍼블릭 라우트 테이블 생성 (인터넷 게이트웨이 경로)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = var.public_rt_tag_name
  }
}

# 퍼블릭 서브넷과 라우트 테이블 연결
resource "aws_route_table_association" "public_assoc" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

########################################
# 프라이빗 서브넷 생성
########################################

# 어플리케이션 인스턴스용 프라이빗 서브넷 (NAT 연결함)
resource "aws_subnet" "private_app" {
  count             = length(var.private_app_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnets[count.index].cidr
  availability_zone = var.private_app_subnets[count.index].az
  map_public_ip_on_launch = false

  tags = {
    Name = "Private-APP-${var.env}-${var.private_app_subnets[count.index].az}"
  }
}

# 데이터베이스 인스턴스용 프라이빗 서브넷 (내부 전용, NAT 연결함)
resource "aws_subnet" "private_db" {
  count             = length(var.private_db_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnets[count.index].cidr
  availability_zone = var.private_db_subnets[count.index].az
  map_public_ip_on_launch = false

  tags = {
    Name = "Private-DB-${var.env}-${var.private_db_subnets[count.index].az}"
  }
}

########################################
# 프라이빗 라우트 테이블 생성 및 서브넷 연결
########################################

# 어플리케이션용 프라이빗 라우트 테이블 (모두 동일한 NAT 사용)
resource "aws_route_table" "private_app_rt" {
  count  = length(var.private_app_subnets)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id  # count 없이 단일 NAT 사용
  }

  tags = {
    Name = "Private-App-RT-${var.env}-${count.index + 1}"
  }
}


resource "aws_route_table_association" "private_app_assoc" {
  count          = length(var.private_app_subnets)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app_rt[count.index].id
}

# 데이터베이스용 프라이빗 라우트 테이블 (모두 동일한 NAT 사용)
resource "aws_route_table" "private_db_rt" {
  count  = length(var.private_db_subnets)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id  # count 없이 단일 NAT 사용
  }

  tags = {
    Name = "Private-DB-RT-${var.env}-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private_db_assoc" {
  count          = length(var.private_db_subnets)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db_rt[count.index].id
}
