import { AmplifyApiGraphQlResourceStackTemplate } from '@aws-amplify/cli-extensibility-helper';

export function override(resources: AmplifyApiGraphQlResourceStackTemplate) {
  if (resources.api && resources.api.GraphQLAPI) {
    resources.api.GraphQLAPI.xrayEnabled = true
    resources.api.GraphQLAPI.addPropertyOverride('LogConfig', {
      FieldLogLevel: 'ERROR',
      ExcludeVerboseContent: true,
      CloudWatchLogsRoleArn: {
        'Fn::Join': [
          '',
          [
            'arn:aws:iam::',
            { Ref: 'AWS::AccountId' },
            ':role/AppsyncCloudWatchRole-',
            { Ref: 'env' },
          ],
        ],
      },
    })
    // Private API: reachable only via the appsync-api interface VPC endpoint.
    // Immutable after creation — changing it replaces the API.
    resources.api.GraphQLAPI.addPropertyOverride('Visibility', 'PRIVATE')
  }
}
