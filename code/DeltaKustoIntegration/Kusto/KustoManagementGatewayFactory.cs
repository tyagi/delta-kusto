﻿using DeltaKustoIntegration.Parameterization;
using DeltaKustoLib;
using Kusto.Data;
using Kusto.Data.Common;
using Kusto.Data.Net.Client;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace DeltaKustoIntegration.Kusto
{
    public class KustoManagementGatewayFactory : IKustoManagementGatewayFactory
    {
        private readonly TokenProviderParameterization _tokenProvider;
        private readonly ITracer _tracer;
        private readonly IDictionary<Uri, ICslAdminProvider> _providerCache =
            new ConcurrentDictionary<Uri, ICslAdminProvider>();

        public KustoManagementGatewayFactory(
            TokenProviderParameterization tokenProvider,
            ITracer tracer)
        {
            _tokenProvider = tokenProvider;
            _tracer = tracer;
        }

        public IKustoManagementGateway CreateGateway(Uri clusterUri, string database)
        {
            ICslAdminProvider? commandProvider;

            //  Make the command provider singleton as they hold HTTP connections
            if (!_providerCache.TryGetValue(clusterUri, out commandProvider))
            {
                lock (_providerCache)
                {   //  Double-check within lock
                    if (!_providerCache.TryGetValue(clusterUri, out commandProvider))
                    {
                        var kustoConnectionStringBuilder = CreateKustoConnectionStringBuilder(
                            clusterUri,
                            _tokenProvider);

                        commandProvider =
                            KustoClientFactory.CreateCslCmAdminProvider(kustoConnectionStringBuilder);

                        _providerCache.Add(clusterUri, commandProvider);
                    }
                }
            }

            return new KustoManagementGateway(
                clusterUri,
                database,
                commandProvider,
                _tracer);
        }

        private static KustoConnectionStringBuilder CreateKustoConnectionStringBuilder(
            Uri clusterUri,
            TokenProviderParameterization tokenProvider)
        {
            var builder = new KustoConnectionStringBuilder(clusterUri.ToString());

            if (tokenProvider.Login != null)
            {
                return builder.WithAadApplicationKeyAuthentication(
                    tokenProvider.Login.ClientId,
                    tokenProvider.Login.Secret,
                    tokenProvider.Login.TenantId);
            }
            else if (tokenProvider.Tokens != null)
            {
                var token = tokenProvider.Tokens.Values
                    .Where(t => t.ClusterUri != null)
                    .Where(t => t.ClusterUri!.Trim().ToLower() == clusterUri.ToString().Trim().ToLower())
                    .Select(t => t.Token)
                    .FirstOrDefault();

                if (token != null)
                {
                    return builder.WithAadUserTokenAuthentication(token);
                }
                else
                {
                    throw new DeltaException($"No token was provided for {clusterUri}");
                }
            }
            else
            {
                throw new NotSupportedException("Token provider isn't supported");
            }
        }
    }
}