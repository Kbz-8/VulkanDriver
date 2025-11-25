# Stroll Vulkan ICD <a href="https://github.com/Kbz-8/VulkanDriver/actions/workflows/Build.yml"><img src="https://github.com/Kbz-8/VulkanDriver/actions/workflows/Build.yml/badge.svg"></a> <a href="https://github.com/Kbz-8/VulkanDriver/actions/workflows/Test.yml"><img src="https://github.com/Kbz-8/VulkanDriver/actions/workflows/Test.yml/badge.svg"></a>

<img align="right" src="https://matthew.kerwin.net.au/blog_files/kappa"/>

A driver as slow as Lance Stroll.

Here lies the source code of a rather calamitous attempt at the Vulkan specification, shaped into an Installable Client Driver for a software-based renderer, all written in Zig.

It was forged for my own learning and amusement alone. Pray, do not wield it in any earnest project, lest thy hopes and frame rates both find themselves entombed.

## Purpose

To understand Vulkan — not as a humble API mere mortals call upon, but as a labyrinthine system where one may craft a driver by hand.
It does not seek to produce a performant or production-worthy driver. \
*The gods are merciful, but not that merciful.*

## Build

If thou art truly determined:
```
zig build
```

Then ensure thy Vulkan loader is pointed toward the ICD manifest.
The precise ritual varies by system — consult the tomes of your operating system, or wander the web’s endless mausoleum of documentation.

Use at your own risk. If thy machine shudders, weeps, or attempts to flee — know that it was warned.
\
\
Thou may also conjure forth a tome of compile commands by doing thus:
```
zig build cdb
```

## Vulkan 1.0 specification

<details>
    <summary>
        The present standing of thy Vulkan 1.0 specification's implementation
    </summary>

\
⚠️ Implemented, yet perchance not fully tested nor proven conformant, but rather working in a manner most general to thee and thine.

Name                                           | Status
-----------------------------------------------|--------
vkAllocateCommandBuffers                       | ✅ Implemented
vkAllocateDescriptorSets                       | ⚙️ WIP
vkAllocateMemory                               | ✅ Implemented
vkBeginCommandBuffer                           | ✅ Implemented
vkBindBufferMemory                             | ✅ Implemented
vkBindImageMemory                              | ✅ Implemented
vkCmdBeginQuery                                | ⚙️ WIP
vkCmdBeginRenderPass                           | ⚙️ WIP
vkCmdBindDescriptorSets                        | ⚙️ WIP
vkCmdBindIndexBuffer                           | ⚙️ WIP
vkCmdBindPipeline                              | ⚙️ WIP
vkCmdBindVertexBuffers                         | ⚙️ WIP
vkCmdBlitImage                                 | ⚙️ WIP
vkCmdClearAttachments                          | ⚙️ WIP
vkCmdClearColorImage                           | ⚙️ WIP
vkCmdClearDepthStencilImage                    | ⚙️ WIP
vkCmdCopyBuffer                                | ✅ Implemented
vkCmdCopyBufferToImage                         | ⚙️ WIP
vkCmdCopyImage                                 | ⚙️ WIP
vkCmdCopyImageToBuffer                         | ❌ Not implemented
vkCmdCopyQueryPoolResults                      | ❌ Not implemented
vkCmdDispatch                                  | ❌ Not implemented
vkCmdDispatchIndirect                          | ❌ Not implemented
vkCmdDraw                                      | ❌ Not implemented
vkCmdDrawIndexed                               | ❌ Not implemented
vkCmdDrawIndexedIndirect                       | ❌ Not implemented
vkCmdDrawIndirect                              | ❌ Not implemented
vkCmdEndQuery                                  | ❌ Not implemented
vkCmdEndRenderPass                             | ❌ Not implemented
vkCmdExecuteCommands                           | ❌ Not implemented
vkCmdFillBuffer                                | ✅ Implemented
vkCmdNextSubpass                               | ❌ Not implemented
vkCmdPipelineBarrier                           | ❌ Not implemented
vkCmdPushConstants                             | ❌ Not implemented
vkCmdResetEvent                                | ❌ Not implemented
vkCmdResetQueryPool                            | ❌ Not implemented
vkCmdResolveImage                              | ❌ Not implemented
vkCmdSetBlendConstants                         | ❌ Not implemented
vkCmdSetDepthBias                              | ❌ Not implemented
vkCmdSetDepthBounds                            | ❌ Not implemented
vkCmdSetEvent                                  | ❌ Not implemented
vkCmdSetLineWidth                              | ❌ Not implemented
vkCmdSetScissor                                | ❌ Not implemented
vkCmdSetStencilCompareMask                     | ❌ Not implemented
vkCmdSetStencilReference                       | ❌ Not implemented
vkCmdSetStencilWriteMask                       | ❌ Not implemented
vkCmdSetViewport                               | ❌ Not implemented
vkCmdUpdateBuffer                              | ❌ Not implemented
vkCmdWaitEvents                                | ❌ Not implemented
vkCmdWriteTimestamp                            | ❌ Not implemented
vkCreateBuffer                                 | ✅ Implemented
vkCreateBufferView                             | ❌ Not implemented
vkCreateCommandPool                            | ❌ Not implemented
vkCreateComputePipelines                       | ❌ Not implemented
vkCreateDescriptorPool                         | ❌ Not implemented
vkCreateDescriptorSetLayout                    | ❌ Not implemented
vkCreateDevice                                 | ✅ Implemented
vkCreateEvent                                  | ❌ Not implemented
vkCreateFence                                  | ✅ Implemented
vkCreateFramebuffer                            | ❌ Not implemented
vkCreateGraphicsPipelines                      | ❌ Not implemented
vkCreateImage                                  | ✅ Implemented
vkCreateImageView                              | ✅ Implemented
vkCreateInstance                               | ✅ Implemented
vkCreatePipelineCache                          | ❌ Not implemented
vkCreatePipelineLayout                         | ❌ Not implemented
vkCreateQueryPool                              | ❌ Not implemented
vkCreateRenderPass                             | ❌ Not implemented
vkCreateSampler                                | ❌ Not implemented
vkCreateSemaphore                              | ❌ Not implemented
vkCreateShaderModule                           | ❌ Not implemented
vkDestroyBuffer                                | ✅ Implemented
vkDestroyBufferView                            | ❌ Not implemented
vkDestroyCommandPool                           | ❌ Not implemented
vkDestroyDescriptorPool                        | ❌ Not implemented
vkDestroyDescriptorSetLayout                   | ❌ Not implemented
vkDestroyDevice                                | ✅ Implemented
vkDestroyEvent                                 | ❌ Not implemented
vkDestroyFence                                 | ✅ Implemented
vkDestroyFramebuffer                           | ❌ Not implemented
vkDestroyImage                                 | ✅ Implemented
vkDestroyImageView                             | ✅ Implemented
vkDestroyInstance                              | ✅ Implemented
vkDestroyPipeline                              | ❌ Not implemented
vkDestroyPipelineCache                         | ❌ Not implemented
vkDestroyPipelineLayout                        | ❌ Not implemented
vkDestroyQueryPool                             | ❌ Not implemented
vkDestroyRenderPass                            | ❌ Not implemented
vkDestroySampler                               | ❌ Not implemented
vkDestroySemaphore                             | ❌ Not implemented
vkDestroyShaderModule                          | ❌ Not implemented
vkDeviceWaitIdle                               | ❌ Not implemented
vkEndCommandBuffer                             | ✅ Implemented
vkEnumerateDeviceExtensionProperties           | ⚙️ WIP
vkEnumerateDeviceLayerProperties               | ⚙️ WIP
vkEnumerateInstanceExtensionProperties         | ⚙️ WIP
vkEnumerateInstanceLayerProperties             | ⚙️ WIP
vkEnumeratePhysicalDevices                     | ✅ Implemented
vkFlushMappedMemoryRanges                      | ❌ Not implemented
vkFreeCommandBuffers                           | ✅ Implemented
vkFreeDescriptorSets                           | ❌ Not implemented
vkFreeMemory                                   | ✅ Implemented
vkGetBufferMemoryRequirements                  | ✅ Implemented
vkGetDeviceMemoryCommitment                    | ❌ Not implemented
vkGetDeviceProcAddr                            | ✅ Implemented
vkGetDeviceQueue                               | ✅ Implemented
vkGetEventStatus                               | ❌ Not implemented
vkGetFenceStatus                               | ✅ Implemented
vkGetImageMemoryRequirements                   | ✅ Implemented
vkGetImageSparseMemoryRequirements             | ❌ Not implemented
vkGetImageSubresourceLayout                    | ❌ Not implemented
vkGetInstanceProcAddr                          | ✅ Implemented
vkGetPhysicalDeviceFeatures                    | ✅ Implemented
vkGetPhysicalDeviceFormatProperties            | ⚙️ WIP
vkGetPhysicalDeviceImageFormatProperties       | ⚙️ WIP
vkGetPhysicalDeviceMemoryProperties            | ✅ Implemented
vkGetPhysicalDeviceProperties                  | ✅ Implemented
vkGetPhysicalDeviceQueueFamilyProperties       | ✅ Implemented
vkGetPhysicalDeviceSparseImageFormatProperties | ⚙️ WIP
vkGetPipelineCacheData                         | ❌ Not implemented
vkGetQueryPoolResults                          | ❌ Not implemented
vkGetRenderAreaGranularity                     | ❌ Not implemented
vkInvalidateMappedMemoryRanges                 | ❌ Not implemented
vkMapMemory                                    | ✅ Implemented
vkMergePipelineCaches                          | ❌ Not implemented
vkQueueBindSparse                              | ❌ Not implemented
vkQueueSubmit                                  | ✅ Implemented
vkQueueWaitIdle                                | ✅ Implemented
vkResetCommandBuffer                           | ✅ Implemented
vkResetCommandPool                             | ❌ Not implemented
vkResetDescriptorPool                          | ❌ Not implemented
vkResetEvent                                   | ❌ Not implemented
vkResetFences                                  | ✅ Implemented
vkSetEvent                                     | ❌ Not implemented
vkUnmapMemory                                  | ✅ Implemented
vkUpdateDescriptorSets                         | ❌ Not implemented
vkWaitForFences                                | ✅ Implemented
</details>

## License

Released unto the world as MIT for study, experimentation, and the occasional horrified whisper.
Do with it as thou wilt, but accept the consequences as thine own.
