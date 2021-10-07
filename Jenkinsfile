pipeline {
    agent any
    stages {
        stage('Init') {
            steps {
                sh "terraform init"
                //sh "terraform destroy"
                //sh 'terraform plan -out=demo.plan'
                //sh 'terraform apply demo.plan'
                //HOLIWIWSSDASD
            }
        }
       
        stage('Validate') {
            steps {
                sh "terraform destroy -auto-aprove"
            }
        }
        
        stage('Plan') {
            steps {
                sh 'yes'
            }
        }
        /*
        stage('Apply') {
            steps {
                sh "terraform apply demo.plan"
            }
        }
        */
    }
}

