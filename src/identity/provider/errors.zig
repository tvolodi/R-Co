pub const ProviderError = error{
    InvalidToken,
    TokenExpired,
    TokenAudienceMismatch,
    TokenIssuerMismatch,
    SignatureVerificationFailed,
    ClaimValidationFailed,

    UserNotFound,
    RealmNotFound,
    ClientNotFound,
    FederationNotFound,

    DuplicateResource,
    Conflict,
    RateLimited,
    UnauthorizedAdminCall,
    ForbiddenAdminCall,

    UpstreamUnavailable,
    UpstreamTimeout,
    UpstreamProtocolError,

    NotImplemented,
    OutOfMemory,
    Internal,
};