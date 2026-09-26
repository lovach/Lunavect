package com.lunavect.sessions;

import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.startup.StartupActivity;
import org.jetbrains.annotations.NotNull;

public final class BridgeStartup implements StartupActivity.DumbAware {
    @Override public void runActivity(@NotNull Project project) {
        ApplicationManager.getApplication().getService(BridgeService.class);
    }
}
