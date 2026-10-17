/// Native-host integration for the reusable Hermes Apps module.
library;

// The user-visible strings of both packages, so a host can reuse the same layer (one entry per language).
export 'package:hermes_surfaces/hermes_surfaces.dart' show SurfacesStrings, SurfacesText;
export 'src/apps_module.dart' show AppsModule;
export 'src/host_bridge.dart' show SurfacesConnection, HostBridge, HostFactory, SurfacePageBuilder, SurfacePageRequest;
export 'src/native_apps_binding.dart' show NativeAppsBinding, NativeAppsPane, NativeControllerFactory;
export 'src/native_legacy_settings.dart' show readLegacyExampleSettings;
export 'src/native_association_controller.dart'
    show
        NativeAssociationController,
        NativeAssociationSettings,
        NativeAssociationConfiguration,
        NativeAssociationNotice,
        NativeAssociationSaveResult,
        NativeClaimResult,
        NativeConnectionCheck;
export 'src/native_association_dialog.dart' show NativeAssociationDialog, showNativeAssociationDialog;
export 'src/native_association_signals.dart'
    show
        NativeOwnerSnapshot,
        nativeContextFingerprint,
        nativeAssociationStorageKey,
        NativeActiveTarget,
        NativeTargetLease,
        NativeMutationTracker,
        NativeMutationOperation,
        NativeMutationOutcome;
export 'src/native_target_routes.dart' show NativeTargetRouteObserver;
