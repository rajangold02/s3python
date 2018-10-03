from __future__ import print_function

import json
import urllib
import boto3
import os

s3 = boto3.client('s3')

def lambda_handler(event, context):
    bucketname = event['detail']['requestParameters']['bucketName']
    try:
        response = s3.get_bucket_tagging(Bucket=bucketname)
        if response['TagSet'][0]['Value'] != 'confidential':
            eventExecution(**event)
        
    except:    
        eventExecution(**event)

def eventExecution(**event):
    allUsersUri = 'http://acs.amazonaws.com/groups/global/AllUsers'
    authenticatedUsersUri = 'http://acs.amazonaws.com/groups/global/AuthenticatedUsers'
    accountid = event['account']
    bucketname = event['detail']['requestParameters']['bucketName']
    publicPermissions = []
    eventName = event['detail']['eventName'];
        
    if eventName == 'PutBucketAcl':
        grants = event['detail']['requestParameters']['AccessControlPolicy']['AccessControlList']['Grant']
        if len(grants) > 1:
            for  grant in grants:
                
                try:
                    if grant['Grantee']['URI'] is not None:
                        if grant['Grantee']['URI'] and (grant['Grantee']['URI'] == allUsersUri or grant['Grantee'][ 'URI'] == authenticatedUsersUri):
                            if 'READ' in grant['Permission']:
                                publicPermissions.append('read')
                            else:
                                publicPermissions.append('write')
                except:
                    print('exception occured..')
                    continue
                
    elif eventName == 'PutBucketPolicy':
        print(eventName)
        policy = event['detail']['requestParameters']['bucketPolicy']['Statement'][0]['Action']
        if policy == 's3:GetObject':
            publicPermissions.append("read")
            print('if: ',publicPermissions)
        elif policy == 's3:PutObject':
            publicPermissions.append("write")
            print('elif: ',publicPermissions)
            
    else:
        # eventType = "created bucket";
        acl =  event['detail']['requestParameters']['x-amz-acl']
        if acl[0] == 'public-read':
            publicPermissions.append("read")
        elif (acl[0] == "public-read-write"):
            publicPermissions.append("read")
            publicPermissions.append("write")  
    
    if len(publicPermissions) != 0:
        print (publicPermissions)
        sns = boto3.client(service_name="sns")
        topicArn = os.environ['snsTopicArn']
        #remove duplicate
        duplicateRemovedLIst = remove(publicPermissions)
        access = ' '
        # get user details
        user = getUserDetails(event)
        sns.publish(
        TopicArn = topicArn,
            Message = 'The following S3 bucket permission has been changed to public ' + access.join(duplicateRemovedLIst) +
            ' Access. \n\n Account_ID: ' +str(accountid)+'\n BucketName: ' +str(bucketname)+'\n IAM User Changed the permission: ' +user
        )
        s3.put_bucket_acl(Bucket = bucketname, ACL = 'private')
    return

def remove(duplicate):
    final_list = []
    for num in duplicate:
        if num not in final_list:
            final_list.append(num)
    return final_list     
    
def getUserDetails(event):

    userIdentity = event['detail']['userIdentity']
    
    
    if userIdentity['type'] == "Root":
        user = "Root"
    elif userIdentity['type'] == "IAMUser":
        user = "IAM user " + userIdentity['userName']
    else:
        user = "Service user" 
    return user