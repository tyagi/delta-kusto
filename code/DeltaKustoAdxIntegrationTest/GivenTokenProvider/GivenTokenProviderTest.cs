using DeltaKustoIntegration.Database;
using DeltaKustoLib;
using DeltaKustoLib.CommandModel;
using Microsoft.IdentityModel.Clients.ActiveDirectory;
using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace DeltaKustoAdxIntegrationTest.GivenTokenProvider
{
    public class GivenTokenProviderTest : AdxIntegrationTestBase
    {
        public GivenTokenProviderTest()
            //  We do not want the login provider as we are testing the given token provider
            : base(false)
        {
        }

        [Fact]
        public async Task TestGivenToken()
        {
            var authenticationContext =
                new AuthenticationContext("https://login.windows.net/" + TenantId);
            var authenticationResult = await authenticationContext.AcquireTokenAsync(
                ClusterUri.ToString(),
                new ClientCredential(ServicePrincipalId, ServicePrincipalSecret));
            var token = authenticationResult.AccessToken;
            var targetDbName = await InitializeDbAsync();
            var overrides = ImmutableArray<(string path, string value)>
                .Empty
                .Add(("jobs.main.target.adx.clusterUri", ClusterUri.ToString()))
                .Add(("jobs.main.target.adx.database", targetDbName))
                .Add(("tokenProvider.tokens.myToken.clusterUri", ClusterUri.ToString()))
                .Add(("tokenProvider.tokens.myToken.token", token));

            await PrepareDbAsync("GivenTokenProvider/target.kql", targetDbName);
            await RunParametersAsync("GivenTokenProvider/given-token.yaml", overrides);

            //  We just test that this doesn't fail
        }
    }
}