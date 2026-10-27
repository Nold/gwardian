package com.monadial.ash.ui.viewmodels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.core.common.AppResult
import com.monadial.ash.core.services.ConnectionTestResult
import com.monadial.ash.domain.repositories.SettingsRepository
import com.monadial.ash.domain.services.RelayService
import com.monadial.ash.domain.usecases.conversation.BurnConversationUseCase
import com.monadial.ash.domain.usecases.conversation.GetConversationsUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * ViewModel for the settings screen.
 *
 * Follows Clean Architecture by:
 * - Using SettingsRepository for settings persistence
 * - Using BurnConversationUseCase for burning all conversations
 * - Using RelayService for connection testing
 */
@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsRepository: SettingsRepository,
    private val relayService: RelayService,
    private val getConversationsUseCase: GetConversationsUseCase,
    private val burnConversationUseCase: BurnConversationUseCase
) : ViewModel() {

    val isBiometricEnabled: StateFlow<Boolean> = settingsRepository.isBiometricEnabled

    private val _lockOnBackground = MutableStateFlow(true)
    val lockOnBackground: StateFlow<Boolean> = _lockOnBackground.asStateFlow()

    // Saved relay URL (from settings)
    private val _relayUrl = MutableStateFlow("")
    val relayUrl: StateFlow<String> = _relayUrl.asStateFlow()

    // Edited relay URL (for UI editing)
    private val _editedRelayUrl = MutableStateFlow("")
    val editedRelayUrl: StateFlow<String> = _editedRelayUrl.asStateFlow()

    // Track if there are unsaved changes
    private val _hasUnsavedChanges = MutableStateFlow(false)
    val hasUnsavedChanges: StateFlow<Boolean> = _hasUnsavedChanges.asStateFlow()

    private val _isTestingConnection = MutableStateFlow(false)
    val isTestingConnection: StateFlow<Boolean> = _isTestingConnection.asStateFlow()

    private val _connectionTestResult = MutableStateFlow<ConnectionTestResult?>(null)
    val connectionTestResult: StateFlow<ConnectionTestResult?> = _connectionTestResult.asStateFlow()

    private val _isBurningAll = MutableStateFlow(false)
    val isBurningAll: StateFlow<Boolean> = _isBurningAll.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    init {
        observeSettings()
    }

    private fun observeSettings() {
        viewModelScope.launch {
            settingsRepository.lockOnBackground.collect {
                _lockOnBackground.value = it
            }
        }
        viewModelScope.launch {
            settingsRepository.relayServerUrl.collect { url ->
                _relayUrl.value = url
                // Only update edited URL if there are no unsaved changes
                if (!_hasUnsavedChanges.value) {
                    _editedRelayUrl.value = url
                }
            }
        }
        // Track unsaved changes
        viewModelScope.launch {
            combine(_relayUrl, _editedRelayUrl) { saved, edited ->
                saved != edited
            }.collect {
                _hasUnsavedChanges.value = it
            }
        }
    }

    fun setEditedRelayUrl(url: String) {
        _editedRelayUrl.value = url
        // Clear test result when URL changes
        _connectionTestResult.value = null
    }

    fun saveRelayUrl() {
        viewModelScope.launch {
            when (val result = settingsRepository.setRelayUrl(_editedRelayUrl.value)) {
                is AppResult.Success -> _error.value = null
                is AppResult.Error -> _error.value = result.error.message
            }
        }
    }

    fun resetRelayUrl() {
        _editedRelayUrl.value = settingsRepository.getDefaultRelayUrl()
        _connectionTestResult.value = null
    }

    fun discardChanges() {
        _editedRelayUrl.value = _relayUrl.value
        _connectionTestResult.value = null
    }

    fun setBiometricEnabled(enabled: Boolean) {
        viewModelScope.launch {
            settingsRepository.setBiometricEnabled(enabled)
        }
    }

    fun setLockOnBackground(enabled: Boolean) {
        viewModelScope.launch {
            settingsRepository.setLockOnBackground(enabled)
        }
    }

    fun testConnection() {
        viewModelScope.launch {
            _isTestingConnection.value = true
            _connectionTestResult.value = null
            try {
                // Use the edited URL for testing (allows testing before saving)
                val url = _editedRelayUrl.value
                val result = relayService.testConnection(url)
                _connectionTestResult.value = result
            } catch (e: Exception) {
                _connectionTestResult.value = ConnectionTestResult(
                    success = false,
                    error = e.message
                )
            } finally {
                _isTestingConnection.value = false
            }
        }
    }

    fun burnAllConversations() {
        viewModelScope.launch {
            _isBurningAll.value = true
            try {
                val conversations = getConversationsUseCase.conversations.value
                val burnedCount = burnConversationUseCase.burnAll(conversations)

                if (burnedCount < conversations.size) {
                    _error.value = "Failed to burn some conversations"
                }

                // Reload to update UI
                getConversationsUseCase.refresh()
            } finally {
                _isBurningAll.value = false
            }
        }
    }

    fun clearError() {
        _error.value = null
    }
}
