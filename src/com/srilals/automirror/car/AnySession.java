package com.srilals.automirror.car;

import android.content.ComponentName;
import android.content.Intent;

import androidx.annotation.NonNull;
import androidx.car.app.CarContext;
import androidx.car.app.Screen;
import androidx.car.app.ScreenManager;
import androidx.car.app.Session;
import androidx.lifecycle.DefaultLifecycleObserver;
import androidx.lifecycle.LifecycleOwner;

import com.srilals.automirror.Apps;
import com.srilals.automirror.Mirror;
import com.srilals.automirror.Prefs;
import com.srilals.automirror.Shell;

/**
 * One car session, one virtual display for its whole life. The root screen is the mirror; the
 * apps grid goes on top of it when no app was shown before (or that app is gone).
 */
public final class AnySession extends Session {
    private Mirror mirror;
    private MirrorScreen screen;

    @NonNull
    @Override
    public Screen onCreateScreen(@NonNull Intent intent) {
        CarContext c = getCarContext();
        Shell.init(c);
        mirror = new Mirror(c, () -> {
            if (screen != null) screen.invalidate();
        }, true);
        screen = new MirrorScreen(c, mirror);
        getLifecycle().addObserver(new DefaultLifecycleObserver() {
            @Override
            public void onDestroy(@NonNull LifecycleOwner owner) {
                mirror.release();
            }
        });
        ComponentName last = Prefs.last(c);
        if (last != null && Apps.find(c, last) != null) {
            mirror.open(last);
            return screen;
        }
        c.getCarService(ScreenManager.class).push(screen);
        return new AppsScreen(c, mirror);
    }
}
