variable "region" {
  description = "Please Specify The Region"
}

variable "access_key" {
  description = "Please Provide Access Key"
}

variable "secret_key" {
  description = "Please Provide Secret Key"
}

variable "alert_email_address" {
  default = "rajr@geakminds.com"
}

variable "cloudtrail_s3_bucket_name" {
  default = "mylogbucketrajebizonus"
}
