using Microsoft.AspNetCore.Authorization;

namespace Hello.Bff;

/// <summary>Satisfied when AUTH_MODE != entra, or when the caller presented a valid Entra ID token.</summary>
public sealed class AuthModeRequirement : IAuthorizationRequirement;

public sealed class AuthModeHandler(BffSettings settings) : AuthorizationHandler<AuthModeRequirement>
{
    protected override Task HandleRequirementAsync(AuthorizationHandlerContext context, AuthModeRequirement requirement)
    {
        ArgumentNullException.ThrowIfNull(context);
        if (settings.AuthMode != "entra" || context.User.Identity?.IsAuthenticated == true)
        {
            context.Succeed(requirement);
        }

        return Task.CompletedTask;
    }
}
