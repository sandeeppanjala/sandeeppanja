variable "region" {
    default = "us-east-1"
}
variable "profile" {
    description = "AWS credentials profile you want to use"
}
variable "key_name" {
    description = "Name of the AWS key pair"
}
variable "public_key_path" {
    description = <<DESCRIPTION
Path to the SSH public key for authentication.
Example: ~/.ssh/terraform-test.pub
DESCRIPTION
}
