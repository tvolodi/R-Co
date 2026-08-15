//! Platform Repository — REPO-01 through REPO-14
//!
//! Versioned, content-addressed artifact store with immutable storage,
//! atomic multi-artifact activation, form schema indexing, event type registry,
//! and service catalog.
//!
//! Design artefact: src/design/repository.md

pub const canonicaliser = @import("canonicaliser.zig");
pub const artifacts = @import("artifacts.zig");
pub const schemas = @import("schemas.zig");
pub const service_catalog = @import("service_catalog.zig");
pub const process_module_catalog = @import("process_module_catalog.zig");
pub const activation = @import("activation.zig");

pub const Canonicaliser = canonicaliser;
pub const Artifacts = artifacts.Artifacts;
pub const Schemas = schemas.Schemas;
pub const ServiceCatalog = service_catalog.ServiceCatalog;
pub const Activation = activation.Activation;

// Re-export public types and errors
pub const CanonicaliserError = canonicaliser.CanonicaliserError;
pub const ArtifactsError = artifacts.ArtifactsError;
pub const SchemasError = schemas.SchemasError;
pub const CatalogError = service_catalog.CatalogError;
pub const ModuleCatalogError = process_module_catalog.ModuleCatalogError;
pub const ActivationError = activation.ActivationError;

pub const ArtifactRecord = artifacts.ArtifactRecord;
pub const ArtifactVersionRecord = artifacts.ArtifactVersionRecord;
pub const CreateArtifactParams = artifacts.CreateArtifactParams;
pub const CreateArtifactResult = artifacts.CreateArtifactResult;
pub const FormSchemaField = schemas.FormSchemaField;
pub const FormSchemaIndexParams = schemas.FormSchemaIndexParams;
pub const ServiceCatalogRecord = service_catalog.ServiceCatalogRecord;
pub const AuthMethod = service_catalog.AuthMethod;
pub const ProcessModuleCatalogEntry = process_module_catalog.ProcessModuleCatalogEntry;
pub const ModuleRef = process_module_catalog.ModuleRef;
pub const ModuleRefResolution = process_module_catalog.ModuleRefResolution;
pub const CompatibilityWarning = process_module_catalog.CompatibilityWarning;
pub const PublishModuleResult = process_module_catalog.PublishModuleResult;
pub const ArtifactActivation = activation.ArtifactActivation;
pub const ActivationHistoryRecord = activation.ActivationHistoryRecord;
pub const ActivationGroupMember = activation.ActivationGroupMember;
pub const ActivateGroupParams = activation.ActivateGroupParams;
pub const ActivateGroupResult = activation.ActivateGroupResult;

pub const Uuid = artifacts.Uuid;
