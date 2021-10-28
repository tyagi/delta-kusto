/**************************************************/
//  Deploy an ADX cluster with multiple databases
//  ready to accomodate integration tests
//
//  A Logic App is deployed to shutdown the cluster
//  within 2-5 hours

@description('Tenant ID (for client id)')
param tenantId string
@description('Service Principal Client ID (which should be cluster admin)')
param clientId string

var uniqueId = uniqueString(resourceGroup().id, 'delta-kusto')
var clusterName = 'intTests${uniqueId}'
var prefixes = [
    'github_linux_'
    'github_win_'
    'github_mac_os_'
]
var dbCountPerPrefix = 25
var shutdownWorkflowName = 'shutdownWorkflow3'
var shutdownWorkflowName2 = 'shutdownWorkflow2'

resource cluster 'Microsoft.Kusto/clusters@2021-01-01' = {
    name: clusterName
    location: resourceGroup().location
    tags: {
        'auto-shutdown': 'true'
    }
    sku: {
        'name': 'Dev(No SLA)_Standard_E2a_v4'
        'tier': 'Basic'
        'capacity': 1
    }

    resource admin 'principalAssignments' = {
        name: 'main-admin'
        properties: {
            principalId: clientId
            principalType: 'App'
            role: 'AllDatabasesAdmin'
            tenantId: tenantId
        }
    }
}

resource dbs 'Microsoft.Kusto/clusters/databases@2021-01-01' = [for i in range(0, length(prefixes)*dbCountPerPrefix): {
    name: '${prefixes[i / dbCountPerPrefix]}${i % dbCountPerPrefix}'
    location: resourceGroup().location
    parent: cluster
    kind: 'ReadWrite'
}]

resource autoShutdownBackup 'Microsoft.Logic/workflows@2019-05-01' = {
    name: shutdownWorkflowName2
    location: resourceGroup().location
    identity: {
        type: 'SystemAssigned'
    }
    properties: {
        state: 'Enabled'
        definition: {
            '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
            contentVersion: '1.0.0.0'
            parameters: {}
            triggers: {
                Recurrence: {
                    recurrence: {
                        frequency: 'Hour'
                        interval: 2
                    }
                    evaluatedRecurrence: {
                        frequency: 'Hour'
                        interval: 2
                    }
                    type: 'Recurrence'
                }
            }
            actions: {
                'get-state': {
                    runAfter: {}
                    type: 'Http'
                    inputs: {
                        authentication: {
                            audience: environment().authentication.audiences[0]
                            type: 'ManagedServiceIdentity'
                        }
                        method: 'GET'
                        uri: '${environment().resourceManager}subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Kusto/clusters/${cluster.name}?api-version=2021-01-01'
                    }
                }
                'if-running': {
                    actions: {
                        'stop-cluster': {
                            runAfter: {
                                wait: [
                                    'Succeeded'
                                ]
                            }
                            type: 'Http'
                            inputs: {
                                authentication: {
                                    audience: environment().authentication.audiences[0]
                                    type: 'ManagedServiceIdentity'
                                }
                                method: 'POST'
                                uri: '${environment().resourceManager}subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Kusto/clusters/${cluster.name}/stop?api-version=2021-01-01'
                            }
                        }
                        wait: {
                            runAfter: {}
                            type: 'Wait'
                            inputs: {
                                interval: {
                                    count: 1
                                    unit: 'Hour'
                                }
                            }
                        }
                    }
                    runAfter: {
                        'parse-payload': [
                            'Succeeded'
                        ]
                    }
                    expression: {
                        and: [
                            {
                                equals: [
                                    '@body(\'parse-payload\')?[\'properties\']?[\'state\']'
                                    'Running'
                                ]
                            }
                        ]
                    }
                    type: 'If'
                }
                'parse-payload': {
                    runAfter: {
                        'get-state': [
                            'Succeeded'
                        ]
                    }
                    type: 'ParseJson'
                    inputs: {
                        content: '@body(\'get-state\')'
                        schema: {
                            properties: {
                                properties: {
                                    properties: {
                                        state: {
                                            type: 'string'
                                        }
                                    }
                                    type: 'object'
                                }
                            }
                            type: 'object'
                        }
                    }
                }
            }
            outputs: {}
        }
        parameters: {}
    }
}

resource autoShutdown 'Microsoft.Logic/workflows@2019-05-01' = {
    name: shutdownWorkflowName
    location: resourceGroup().location
    identity: {
        type: 'SystemAssigned'
    }
    properties: {
        state: 'Enabled'
        definition: {
            '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
            contentVersion: '1.0.0.0'
            parameters: {}
            triggers: {
              Recurrence: {
                recurrence: {
                  frequency: 'Hour'
                  interval: 2
                }
                evaluatedRecurrence: {
                  frequency: 'Hour'
                  interval: 2
                }
                type: 'Recurrence'
              }
            }
            actions: {
              'for-each-cluster': {
                foreach: '@body(\'get-clusters\').value'
                actions: {
                  'if-should-shut-down': {
                    actions: {
                      'stop-cluster': {
                        runAfter: {
                          wait: [
                            'Succeeded'
                          ]
                        }
                        type: 'Http'
                        inputs: {
                          authentication: {
                            audience: environment().authentication.audiences[0]
                            type: 'ManagedServiceIdentity'
                          }
                          method: 'POST'
                          uri: '@{outputs(\'stop-cluster-url\')}'
                        }
                      }
                      'stop-cluster-url': {
                        runAfter: {}
                        type: 'Compose'
                        inputs: '@concat(\'subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Kusto/clusters/\', body(\'parse-payload\')?[\'name\'], \'/stop?api-version=2021-01-01\')'
                      }
                      wait: {
                        runAfter: {
                          'stop-cluster-url': [
                            'Succeeded'
                          ]
                        }
                        type: 'Wait'
                        inputs: {
                          interval: {
                            count: 1
                            unit: 'Hour'
                          }
                        }
                      }
                    }
                    runAfter: {
                      'parse-payload': [
                        'Succeeded'
                      ]
                    }
                    expression: {
                      and: [
                        {
                          equals: [
                            '@body(\'parse-payload\')?[\'tags\']?[\'auto-shutdown\']'
                            'true'
                          ]
                        }
                        {
                          equals: [
                            '@body(\'parse-payload\')?[\'properties\']?[\'state\']'
                            'Running'
                          ]
                        }
                      ]
                    }
                    type: 'If'
                  }
                  'parse-payload': {
                    runAfter: {}
                    type: 'ParseJson'
                    inputs: {
                      content: '@items(\'for-each-cluster\')'
                      schema: {
                        properties: {
                          id: {
                            type: 'string'
                          }
                          name: {
                            type: 'string'
                          }
                          properties: {
                            properties: {
                              state: {
                                type: 'string'
                              }
                            }
                            type: 'object'
                          }
                          tags: {
                            properties: {
                              'auto-shutdown': {
                                type: 'string'
                              }
                            }
                            type: 'object'
                          }
                        }
                        type: 'object'
                      }
                    }
                  }
                }
                runAfter: {
                  'get-clusters': [
                    'Succeeded'
                  ]
                }
                type: 'Foreach'
                runtimeConfiguration: {
                  concurrency: {
                    repetitions: 50
                  }
                }
              }
              'get-clusters': {
                runAfter: {}
                type: 'Http'
                inputs: {
                  authentication: {
                    audience: environment().authentication.audiences[0]
                    type: 'ManagedServiceIdentity'
                  }
                  method: 'GET'
                  uri: '${environment().resourceManager}subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.Kusto/clusters?api-version=2021-01-01'
                }
              }
            }
            outputs: {}
          }
        }
}

var contributorId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var fullRoleDefinitionId = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/${contributorId}'
var autoShutdownAssignmentInner = '${resourceGroup().id}${fullRoleDefinitionId}'
var autoShutdownAssignmentName = '${cluster.name}/Microsoft.Authorization/${guid(autoShutdownAssignmentInner)}'

resource autoShutdownAuthorization 'Microsoft.Kusto/clusters/providers/roleAssignments@2021-04-01-preview' = {
    name: autoShutdownAssignmentName
    properties: {
        description: 'Give contributor on the cluster'
        principalId: autoShutdown.identity.principalId
        roleDefinitionId: fullRoleDefinitionId
    }
}
