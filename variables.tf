variable region {
    default = "us-east-2"
    type = string
}
variable proyect_name {
    default = "rdmx"
    type = "string"
}

variable ami {
    default = "ami-05bc9d8ed549406b2"
    type = string
}
variable hosted_zone{
    default =  "jamonsito.link"
    type = string
}
variable hosted_zone_id{
    default = "Z09868992UZHKNW59XYYU"
    type = string
}

variable subcriptions_emails{
    default = [ "mariost1995@hotmail.com" ]
    type = list(string)
}