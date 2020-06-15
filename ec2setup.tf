provider "aws" {
  region = "ap-south-1"
  profile = "shivam"
}

resource "tls_private_key" "terraos_key" {
algorithm = "RSA"
}

resource "aws_key_pair" "deployment_key" {
  key_name = "terraos_key"
  public_key = tls_private_key.terraos_key.public_key_openssh
  depends_on = [
    tls_private_key.terraos_key
  ]
}

resource "local_file" "key-file" {
  content = tls_private_key.terraos_key.private_key_pem
  filename = "terraoskey.pem"
  depends_on = [
    tls_private_key.terraos_key
  ]
}

resource "aws_security_group" "allow_tls" {
  name        = "allow_tls"
  description = "Allow TLS inbound traffic"
  vpc_id      = "vpc-47ebf62f"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_tls"
  }
}

resource "aws_instance" "webhttpd" {
  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = aws_key_pair.deployment_key.key_name
  security_groups = [ "allow_tls" ]

  connection {
    type   = "ssh"
    user   = "ec2-user"
    private_key = tls_private_key.terraos_key.private_key_pem
    host   = aws_instance.webhttpd.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd  php git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd",
    ]
  }

  tags = {
    Name = "httpdos"
  }

}

resource "aws_ebs_volume" "ebs" {
  availability_zone = aws_instance.webhttpd.availability_zone
  size              = 1
  tags = {
    Name = "ebs1"
  }
}

resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ebs.id
  instance_id = aws_instance.webhttpd.id
  force_detach = true
}

output "webos_ip" {
  value = aws_instance.webhttpd.public_ip
}

resource "null_resource" "nulllocal1" {
  provisioner "local-exec" {
    command = "echo  ${aws_instance.webhttpd.public_ip} > publicip.txt"
  }
}

resource "null_resource" "nullremote1"  {

  depends_on = [
    aws_volume_attachment.ebs_att
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.terraos_key.private_key_pem
    host     = aws_instance.webhttpd.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4  /dev/xvdh",
      "sudo mount  /dev/xvdh  /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/Shivamshiv/multicloud.git /var/www/html/"
    ]
  }
}

resource "aws_s3_bucket" "s3-bucket-12321" {
  depends_on = [
    aws_instance.webhttpd
  ]

  bucket = "s3-bucket-12321"
  acl    = "public-read"
  region = "ap-south-1"
  tags = {
    Name = "my_bucket"
    Environment = "Deployment"
  }
}

locals {
  s3_origin_id = "S3-s3-bucket-12321"
}

resource "aws_s3_bucket_public_access_block" "s3-bucket-12321_public" {
  bucket = "s3-bucket-12321"
  block_public_acls   = false
  block_public_policy = false
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "Some comment"
}

resource "aws_cloudfront_distribution" "s3-12321-cloud-front" {

  origin {
    domain_name = aws_s3_bucket.s3-bucket-12321.bucket_regional_domain_name
    origin_id   = local.s3_origin_id
 
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }

  }

  enabled             = true
  is_ipv6_enabled     = true

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "blacklist"
      locations        = ["AF", "DZ", "AD", "AX"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "myos_ip" {
  value = aws_instance.webhttpd.public_ip
}

data "aws_iam_policy_document" "s3_bucket_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.s3-bucket-12321.arn}/*"]


    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }
}

resource "aws_s3_bucket_policy" "example" {
  bucket = "s3-bucket-12321"
  policy = data.aws_iam_policy_document.s3_bucket_policy.json
}

