package com.monadial.ash.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.monadial.ash.core.services.applock.LockPhase
import com.monadial.ash.ui.screens.CeremonyScreen
import com.monadial.ash.ui.screens.ConversationInfoScreen
import com.monadial.ash.ui.screens.ConversationsScreen
import com.monadial.ash.ui.screens.GroupCeremonyScreen
import com.monadial.ash.ui.screens.LockScreen
import com.monadial.ash.ui.screens.MessagingScreen
import com.monadial.ash.ui.screens.PasscodeSetupScreen
import com.monadial.ash.ui.screens.SettingsScreen
import com.monadial.ash.ui.viewmodels.GroupRole
import com.monadial.ash.ui.viewmodels.LockViewModel

sealed class Screen(val route: String) {
    data object Conversations : Screen("conversations")

    data object Messaging : Screen("messaging/{conversationId}") {
        fun createRoute(conversationId: String) = "messaging/$conversationId"
    }

    data object ConversationInfo : Screen("conversation-info/{conversationId}") {
        fun createRoute(conversationId: String) = "conversation-info/$conversationId"
    }

    data object Ceremony : Screen("ceremony")

    data object GroupCeremony : Screen("group-ceremony/{role}") {
        fun createRoute(role: GroupRole) = "group-ceremony/${role.name}"
    }

    data object Settings : Screen("settings")
}

/** The app code gates everything (docs/app-lock.md). */
@Composable
fun AshApp(lockViewModel: LockViewModel = hiltViewModel()) {
    val lockState by lockViewModel.state.collectAsState()

    when (lockState.phase) {
        LockPhase.SETUP -> PasscodeSetupScreen(lockViewModel)
        LockPhase.LOCKED -> LockScreen(lockViewModel)
        LockPhase.UNLOCKED -> UnlockedApp()
    }
}

@Composable
private fun UnlockedApp() {
    val navController = rememberNavController()

    // Leaving this branch means the app locked: pop every screen so their
    // view models, and what they read from the vault, are cleared
    DisposableEffect(navController) {
        onDispose {
            runCatching { navController.popBackStack(navController.graph.id, inclusive = true) }
        }
    }

    NavHost(
        navController = navController,
        startDestination = Screen.Conversations.route
    ) {
        composable(Screen.Conversations.route) {
            ConversationsScreen(
                onConversationClick = { conversationId ->
                    navController.navigate(Screen.Messaging.createRoute(conversationId))
                },
                onNewConversation = {
                    navController.navigate(Screen.Ceremony.route)
                },
                onNewGroup = {
                    navController.navigate(Screen.GroupCeremony.createRoute(GroupRole.CREATOR))
                },
                onJoinGroup = {
                    navController.navigate(Screen.GroupCeremony.createRoute(GroupRole.JOINER))
                },
                onSettingsClick = {
                    navController.navigate(Screen.Settings.route)
                }
            )
        }

        composable(
            route = Screen.Messaging.route,
            arguments = listOf(navArgument("conversationId") { type = NavType.StringType })
        ) { backStackEntry ->
            val conversationId = backStackEntry.arguments?.getString("conversationId") ?: return@composable
            MessagingScreen(
                conversationId = conversationId,
                onBack = { navController.popBackStack() },
                onInfoClick = { navController.navigate(Screen.ConversationInfo.createRoute(conversationId)) }
            )
        }

        composable(
            route = Screen.ConversationInfo.route,
            arguments = listOf(navArgument("conversationId") { type = NavType.StringType })
        ) { backStackEntry ->
            val conversationId = backStackEntry.arguments?.getString("conversationId") ?: return@composable
            ConversationInfoScreen(
                conversationId = conversationId,
                onBack = { navController.popBackStack() },
                onBurned = {
                    navController.navigate(Screen.Conversations.route) {
                        popUpTo(Screen.Conversations.route) { inclusive = true }
                    }
                }
            )
        }

        composable(route = Screen.Ceremony.route) {
            CeremonyScreen(
                onComplete = { conversationId ->
                    navController.navigate(Screen.Messaging.createRoute(conversationId)) {
                        popUpTo(Screen.Conversations.route)
                    }
                },
                onCancel = { navController.popBackStack() }
            )
        }

        composable(
            route = Screen.GroupCeremony.route,
            arguments = listOf(navArgument("role") { type = NavType.StringType })
        ) {
            // The view model reads the role from the navigation argument
            GroupCeremonyScreen(
                onComplete = { navController.popBackStack() },
                onCancel = { navController.popBackStack() }
            )
        }

        composable(Screen.Settings.route) {
            SettingsScreen(
                onBack = { navController.popBackStack() }
            )
        }
    }
}
