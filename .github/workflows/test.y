

    
    - name: Describe ECS Services (Debugging)
      env:
        ECS_SERVICE: test_nbbo
      run: aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE

    - name: Check if ECS Task Definition Exists
      id: check_task_definition
      env:
        TASK_DEFINITION_TAG: nbbo
      run: |
        TASK_DEF_EXISTS=$(aws ecs describe-task-definition --task-definition $TASK_DEFINITION_TAG | jq ".taskDefinition.taskDefinitionArn" || echo "")
        if [ -z "$TASK_DEF_EXISTS" ]; then
          echo "TASK_DEFINITION_DOES_NOT_EXIST=true" >> $GITHUB_ENV
        else
          echo "TASK_DEFINITION_DOES_NOT_EXIST=false" >> $GITHUB_ENV
        fi

    - name: Create ECS Task Definition
      env:
        ECR_REGISTRY: ${{steps.login-ecr.outputs.registry}}
        TASK_DEFINITION_TAG: nbbo
      #if: env.TASK_DEFINITION_DOES_NOT_EXIST == 'true'
      run: |
        aws ecs register-task-definition \
        --family ${{env.TASK_DEFINITION_TAG}} \
        --network-mode awsvpc \
        --container-definitions '[
          {
            "name": "mycontainer",
            "image": "${{env.ECR_REGISTRY}}/${{env.REPO_NAME}}:${{env.IMAGE_TAG}}",
            "cpu": 200,
            "memory": 200,
            "memoryReservation": 200,
            "essential": true,
            "command": ["python", "-m", "${{env.TASK_DEFINITION_TAG}}"],
            "workingDirectory": "/code/feed/",
            "mountPoints": [
              {
                "sourceVolume": "configVolume",
                "containerPath": "/config_cf.yaml",
                "readOnly": false
              }
            ],
            "logConfiguration": {
              "logDriver": "awslogs",
              "options": {
                "awslogs-create-group": "true",
                "awslogs-group": "mycontainer",
                "awslogs-region": "${{env.AWS_REGION}}",
                "awslogs-stream-prefix": "${{env.TASK_DEFINITION_TAG}}"
              }
            }
          }
        ]' \
        --volumes '[{"name": "configVolume", "host": {"sourcePath": "/config_cf.yaml"}}]' \
        --cpu "200" \
        --memory "200"

# --execution-role-arn arn:aws:iam::${{secrets.AWS_ACCOUNT_ID}}:role/ecsTaskExecutionRole \
# --task-role-arn arn:aws:iam::${{secrets.AWS_ACCOUNT_ID}}:role/ecsTaskRole \




    - name: Delete ECS Service if Inactive
      env:
        ECS_SERVICE: test_nbbo
      run: |
        SERVICE_STATUS=$(aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE | jq -r ".services[] | select(.serviceName == \"${ECS_SERVICE}\") | .status")
        if [ "$SERVICE_STATUS" == "INACTIVE" ]; then
          aws ecs delete-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --force
        fi
#####################to remove this step##################
    - name: Check if ECS Service Exists
      env:
        ECS_SERVICE: test_nbbo
      id: check_service
      run: |
        SERVICE_EXISTS=$(aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE | jq ".services[] | select(.serviceName == \"${ECS_SERVICE}\") | .serviceName")
        if [ -z "$SERVICE_EXISTS" ]; then
          echo "SERVICE_DOES_NOT_EXIST=true" >> $GITHUB_ENV
        else
          echo "SERVICE_DOES_NOT_EXIST=false" >> $GITHUB_ENV
        fi

    - name: Create ECS Service if Not Exists
      env:
        TASK_DEFINITION_TAG: nbbo
        ECS_SERVICE: test_nbbo
      if: env.SERVICE_DOES_NOT_EXIST == 'true'
      run: |
        aws ecs create-service \
          --cluster ${{env.ECS_CLUSTER}} \
          --service-name ${{env.ECS_SERVICE}} \
          --task-definition ${{env.TASK_DEFINITION_TAG}} \
          --desired-count 1 \
          --launch-type EC2 \
          --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=200,minimumHealthyPercent=100" \
          --scheduling-strategy REPLICA \
          --placement-strategy "type=spread,field=attribute:ecs.availability-zone" "type=spread,field=instanceId" \
          --deployment-controller "type=ECS" \
          --network-configuration "awsvpcConfiguration={subnets=[subnet-ab24e2e3,subnet-a035fc8b,subnet-a1d2e2fa],securityGroups=[sg-6c5b961e],assignPublicIp=DISABLED}" \
      

    - name: Deploy to ECS
      env:
          TASK_DEFINITION: nbbo
          ECS_SERVICE: test_nbbo
      run: |
        aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --task-definition ${{env.TASK_DEFINITION}}

    - name: Check ECS Service Status
      env:
          TASK_DEFINITION_TAG: nbbo
          ECS_SERVICE: test_nbbo
      run: |
        aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE


      #don't use if OIDC authentication
      # env:
      #   AWS_ACCESS_KEY_ID: ${{ secrets.AMAZON_ACCESS_KEY }}
      #   AWS_SECRET_ACCESS_KEY: ${{ secrets.AMAZON_SECRET_ACCESS_KEY }}
      #   AWS_REGION: ${{ secrets.AWS_REGION }}