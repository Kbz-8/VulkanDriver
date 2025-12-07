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
vkCmdClearAttachments                          | ⚙️ wip
vkCmdClearColorImage                           | ⚙️ WIP
vkCmdClearDepthStencilImage                    | ⚙️ WIP
vkCmdCopyBuffer                                | ✅ Implemented
vkCmdCopyBufferToImage                         | ⚙️ WIP
vkCmdCopyImage                                 | ⚙️ WIP
vkCmdCopyImageToBuffer                         | ⚙️ WIP
vkCmdCopyQueryPoolResults                      | ⚙️ WIP
vkCmdDispatch                                  | ⚙️ WIP
vkCmdDispatchIndirect                          | ⚙️ WIP
vkCmdDraw                                      | ⚙️ WIP
vkCmdDrawIndexed                               | ⚙️ WIP
vkCmdDrawIndexedIndirect                       | ⚙️ WIP
vkCmdDrawIndirect                              | ⚙️ WIP
vkCmdEndQuery                                  | ⚙️ WIP
vkCmdEndRenderPass                             | ⚙️ WIP
vkCmdExecuteCommands                           | ⚙️ WIP
vkCmdFillBuffer                                | ✅ Implemented
vkCmdNextSubpass                               | ⚙️ WIP
vkCmdPipelineBarrier                           | ⚙️ WIP
vkCmdPushConstants                             | ⚙️ WIP
vkCmdResetEvent                                | ⚙️ WIP
vkCmdResetQueryPool                            | ⚙️ WIP
vkCmdResolveImage                              | ⚙️ WIP
vkCmdSetBlendConstants                         | ⚙️ WIP
vkCmdSetDepthBias                              | ⚙️ WIP
vkCmdSetDepthBounds                            | ⚙️ WIP
vkCmdSetEvent                                  | ⚙️ WIP
vkCmdSetLineWidth                              | ⚙️ WIP
vkCmdSetScissor                                | ⚙️ WIP
vkCmdSetStencilCompareMask                     | ⚙️ WIP
vkCmdSetStencilReference                       | ⚙️ WIP
vkCmdSetStencilWriteMask                       | ⚙️ WIP
vkCmdSetViewport                               | ⚙️ WIP
vkCmdUpdateBuffer                              | ⚙️ WIP
vkCmdWaitEvents                                | ⚙️ WIP
vkCmdWriteTimestamp                            | ⚙️ WIP
vkCreateBuffer                                 | ✅ Implemented
vkCreateBufferView                             | ⚙️ WIP
vkCreateCommandPool                            | ✅ Implemented
vkCreateComputePipelines                       | ⚙️ WIP
vkCreateDescriptorPool                         | ⚙️ WIP
vkCreateDescriptorSetLayout                    | ⚙️ WIP
vkCreateDevice                                 | ✅ Implemented
vkCreateEvent                                  | ⚙️ WIP
vkCreateFence                                  | ✅ Implemented
vkCreateFramebuffer                            | ⚙️ WIP
vkCreateGraphicsPipelines                      | ⚙️ WIP
vkCreateImage                                  | ✅ Implemented
vkCreateImageView                              | ✅ Implemented
vkCreateInstance                               | ✅ Implemented
vkCreatePipelineCache                          | ⚙️ WIP
vkCreatePipelineLayout                         | ⚙️ WIP
vkCreateQueryPool                              | ⚙️ WIP
vkCreateRenderPass                             | ⚙️ WIP
vkCreateSampler                                | ⚙️ WIP
vkCreateSemaphore                              | ⚙️ WIP
vkCreateShaderModule                           | ⚙️ WIP
vkDestroyBuffer                                | ✅ Implemented
vkDestroyBufferView                            | ⚙️ WIP
vkDestroyCommandPool                           | ✅ Implemented
vkDestroyDescriptorPool                        | ⚙️ WIP
vkDestroyDescriptorSetLayout                   | ⚙️ WIP
vkDestroyDevice                                | ✅ Implemented
vkDestroyEvent                                 | ⚙️ WIP
vkDestroyFence                                 | ✅ Implemented
vkDestroyFramebuffer                           | ⚙️ WIP
vkDestroyImage                                 | ✅ Implemented
vkDestroyImageView                             | ✅ Implemented
vkDestroyInstance                              | ✅ Implemented
vkDestroyPipeline                              | ⚙️ WIP
vkDestroyPipelineCache                         | ⚙️ WIP
vkDestroyPipelineLayout                        | ⚙️ WIP
vkDestroyQueryPool                             | ⚙️ WIP
vkDestroyRenderPass                            | ⚙️ WIP
vkDestroySampler                               | ⚙️ WIP
vkDestroySemaphore                             | ⚙️ WIP
vkDestroyShaderModule                          | ⚙️ WIP
vkDeviceWaitIdle                               | ⚙️ WIP
vkEndCommandBuffer                             | ✅ Implemented
vkEnumerateDeviceExtensionProperties           | ⚙️ WIP
vkEnumerateDeviceLayerProperties               | ⚙️ WIP
vkEnumerateInstanceExtensionProperties         | ⚙️ WIP
vkEnumerateInstanceLayerProperties             | ⚙️ WIP
vkEnumeratePhysicalDevices                     | ✅ Implemented
vkFlushMappedMemoryRanges                      | ⚙️ WIP
vkFreeCommandBuffers                           | ✅ Implemented
vkFreeDescriptorSets                           | ⚙️ WIP
vkFreeMemory                                   | ✅ Implemented
vkGetBufferMemoryRequirements                  | ✅ Implemented
vkGetDeviceMemoryCommitment                    | ⚙️ WIP
vkGetDeviceProcAddr                            | ✅ Implemented
vkGetDeviceQueue                               | ✅ Implemented
vkGetEventStatus                               | ⚙️ WIP
vkGetFenceStatus                               | ✅ Implemented
vkGetImageMemoryRequirements                   | ✅ Implemented
vkGetImageSparseMemoryRequirements             | ⚙️ WIP
vkGetImageSubresourceLayout                    | ⚙️ WIP
vkGetInstanceProcAddr                          | ✅ Implemented
vkGetPhysicalDeviceFeatures                    | ✅ Implemented
vkGetPhysicalDeviceFormatProperties            | ⚙️ WIP
vkGetPhysicalDeviceImageFormatProperties       | ⚙️ WIP
vkGetPhysicalDeviceMemoryProperties            | ✅ Implemented
vkGetPhysicalDeviceProperties                  | ✅ Implemented
vkGetPhysicalDeviceQueueFamilyProperties       | ✅ Implemented
vkGetPhysicalDeviceSparseImageFormatProperties | ⚙️ WIP
vkGetPipelineCacheData                         | ⚙️ WIP
vkGetQueryPoolResults                          | ⚙️ WIP
vkGetRenderAreaGranularity                     | ⚙️ WIP
vkInvalidateMappedMemoryRanges                 | ⚙️ WIP
vkMapMemory                                    | ✅ Implemented
vkMergePipelineCaches                          | ⚙️ WIP
vkQueueBindSparse                              | ⚙️ WIP
vkQueueSubmit                                  | ✅ Implemented
vkQueueWaitIdle                                | ✅ Implemented
vkResetCommandBuffer                           | ✅ Implemented
vkResetCommandPool                             | ⚙️ WIP
vkResetDescriptorPool                          | ⚙️ WIP
vkResetEvent                                   | ⚙️ WIP
vkResetFences                                  | ✅ Implemented
vkSetEvent                                     | ⚙️ WIP
vkUnmapMemory                                  | ✅ Implemented
vkUpdateDescriptorSets                         | ⚙️ WIP
vkWaitForFences                                | ✅ Implemented
</details>

\
[Here](https://vulkan-driver-cts-report.kbz8.me/) shalt thou find a most meticulous account of the Vulkan 1.0 conformance trials, set forth for thy scrutiny.

## License

Released unto the world as MIT for study, experimentation, and the occasional horrified whisper.
Do with it as thou wilt, but accept the consequences as thine own.
