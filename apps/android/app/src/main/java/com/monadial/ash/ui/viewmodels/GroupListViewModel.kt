package com.monadial.ash.ui.viewmodels

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.monadial.ash.data.repositories.GroupRepository
import com.monadial.ash.domain.entities.GroupConversation
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Group conversations shown above the two-person conversations. */
@HiltViewModel
class GroupListViewModel @Inject constructor(
    private val groupRepository: GroupRepository
) : ViewModel() {

    private val _groups = MutableStateFlow<List<GroupConversation>>(emptyList())
    val groups: StateFlow<List<GroupConversation>> = _groups.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _groups.value = runCatching { groupRepository.load() }.getOrDefault(emptyList())
        }
    }

    /** Delete the group and its pads from this phone only. */
    fun delete(group: GroupConversation) {
        viewModelScope.launch {
            groupRepository.delete(group.id)
            refresh()
        }
    }
}
