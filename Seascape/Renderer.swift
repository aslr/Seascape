//
//  Renderer.swift
//  Seascape
//
//  Created by João Varela on 05/08/2018.
//  Copyright © 2018 João Varela. All rights reserved.
//

// Our platform independent renderer class

import MetalKit
import simd

class Renderer: NSObject, MTKViewDelegate
{
    // time
    let timeStep = Float(1.0/60.0)
    var time = Float(0)
    
    // mouse
    var mouse = NSPoint(x: 0, y: 0)
    
    public let device: MTLDevice
    
    // private ivars for triple buffering
    private let textureCount = 3
    private var textureQueue:[MTLTexture]!
    private var currentTexture:MTLTexture!
    
    // other ivars
    private var view:MTKView
    private let commandQueue: MTLCommandQueue
    private let library:MTLLibrary!
    private let screenQuad:MTLBuffer!
    private var renderState:MTLRenderPipelineState!
    private var computeState: MTLComputePipelineState!
    private var inputBuffer: MTLBuffer!
    private var semaphore: DispatchSemaphore!
    
    // ---------------------------------------------------------------------------------
    // init
    // ---------------------------------------------------------------------------------
    init?(metalKitView: MTKView)
    {
        self.device = metalKitView.device!
        self.commandQueue = device.makeCommandQueue()!
        self.view = metalKitView
        self.textureQueue = []
        self.library = device.makeDefaultLibrary()!
        self.screenQuad = Renderer.makeScreenMesh(device: device)
        super.init()
        self.computeState = makeComputePipeline()
        self.renderState = makeRenderPipeline()!
        guard let layer = metalKitView.layer as? CAMetalLayer else { fatalError() }
        makeScreenTextures(size: metalKitView.drawableSize, scale: layer.contentsScale)
        self.semaphore = DispatchSemaphore(value: textureCount)
    }
    
    // ---------------------------------------------------------------------------------
    // draw
    // ---------------------------------------------------------------------------------
    func draw(in view: MTKView)
    {
        _ = semaphore.wait(timeout: .distantFuture)
        time += timeStep
        let inputBufferPtr = inputBuffer.contents().bindMemory(to: float4.self, capacity: 1)
        inputBufferPtr.pointee = float4(Float(mouse.x),Float(mouse.y),0.0,time)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let blockSemaphore = semaphore
        commandBuffer.addCompletedHandler({_ in blockSemaphore?.signal()})
        encodeCompute(commandBuffer)
        
        if let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable
        {
            encodeRender(buffer: commandBuffer, descriptor: rpd)       
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
    
    // ---------------------------------------------------------------------------------
    // encodeCompute
    // ---------------------------------------------------------------------------------
    private func encodeCompute(_ commandBuffer:MTLCommandBuffer)
    {
        guard let writeTexture = textureQueue.first else { fatalError() }
        guard let commandEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        commandEncoder.setComputePipelineState(computeState)
        commandEncoder.setTexture(currentTexture, index: 0)
        commandEncoder.setTexture(writeTexture, index: 1)
        commandEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        let w = computeState.threadExecutionWidth
        let h = computeState.maxTotalThreadsPerThreadgroup / w;
        let threadGroupCount = MTLSize(width: w, height: h, depth: 1)
        let threadGroups = MTLSize(width: (writeTexture.width + w - 1) / w,
                                   height: (writeTexture.height + h - 1) / h,
                                   depth: 1)
        commandEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupCount)
        commandEncoder.endEncoding()
        rotateTextures()
    }
    
    // ---------------------------------------------------------------------------------
    // encodeRender
    // ---------------------------------------------------------------------------------
    // Encodes the renderer of the full screen quad
    private func encodeRender(buffer:MTLCommandBuffer, descriptor:MTLRenderPassDescriptor)
    {
        // Create a render command encoder, which we can use to encode draw calls into the buffer
        let renderEncoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        
        // Configure the render encoder for drawing the full-screen quad, then issue the draw call
        renderEncoder?.setRenderPipelineState(renderState)
        renderEncoder?.setVertexBuffer(screenQuad, offset: 0, index: 0)
        renderEncoder?.setFragmentTexture(currentTexture, index: 0)
        renderEncoder?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder?.endEncoding()
    }
    
    // ---------------------------------------------------------------------------------
    // makeComputePipeline
    // ---------------------------------------------------------------------------------
    private func makeComputePipeline() -> MTLComputePipelineState?
    {
        do {
            if let kernel = library.makeFunction(name: "compute")
            {
                self.inputBuffer = device.makeBuffer(length: MemoryLayout<float4>.size, options: [])
                return try device.makeComputePipelineState(function: kernel)
            }
            else
            {
                view.printView("Setting compute pipeline state failed")
            }
        }
            
        catch let error {
            view.printView("\(error)")
        }
        
        return nil
    }
    
    // ---------------------------------------------------------------------------------
    // makeRenderPipeline
    // ---------------------------------------------------------------------------------
    private func makeRenderPipeline() -> MTLRenderPipelineState?
    {
        // Create a vertex descriptor that describes a vertex with two float2 members:
        // position and texture coordinates
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 2
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 4
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        // Describe and create a render pipeline state
        let vertexFunction = library.makeFunction(name: "fullscreen_vertex_func")
        let fragmentFunction = library.makeFunction(name: "fullscreen_fragment_func")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Fullscreen Pipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do
        {
            let renderState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            return renderState
        }
            
        catch let error
        {
            print("\(error)")
            fatalError()
        }
        
        return nil
    }
    
    // ---------------------------------------------------------------------------------
    // makeScreenMesh                                                           class
    // ---------------------------------------------------------------------------------
    private class func makeScreenMesh(device:MTLDevice) -> MTLBuffer
    {
        // Vertex data for a full-screen quad. The first two numbers in each row represent
        // the x, y position of the point in normalized coordinates. The second two numbers
        // represent the texture coordinates for the corresponding position.
        let vertexData:[Float] = [
            -1,  1, 0, 0,
            -1, -1, 0, 1,
            1, -1, 1, 1,
            1, -1, 1, 1,
            1,  1, 1, 0,
            -1,  1, 0, 0
        ]
        
        let length = vertexData.count * MemoryLayout<Float>.size
        guard let mesh = device.makeBuffer(length: length, options: .storageModeManaged)
            else { fatalError() }
        let meshPtr = mesh.contents().bindMemory(to: Float.self, capacity: vertexData.count)
        meshPtr.assign(from: vertexData, count: vertexData.count)
        mesh.didModifyRange(0..<length)
        return mesh
    }
    
    // ---------------------------------------------------------------------------------
    // makeScreenTextures
    // ---------------------------------------------------------------------------------
    private func makeScreenTextures(size:CGSize, scale:CGFloat)
    {
        textureQueue.removeAll()
        currentTexture = nil
        guard let metalLayer = view.layer as? CAMetalLayer else { fatalError() }
        let pixelformat = metalLayer.pixelFormat
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelformat,
                                                                  width: Int(size.width),
                                                                  height: Int(size.height),
                                                                  mipmapped: false)
        
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        for i in 0..<textureCount
        {
            guard let texture = device.makeTexture(descriptor: descriptor) else { fatalError() }
            texture.label = "Seascape #\(i)"
            textureQueue.append(texture)
        }
    }
    
    // ---------------------------------------------------------------------------------
    // mtkView(_:drawableSizeWillChange)
    // ---------------------------------------------------------------------------------
    // Callback when the user changes the size of the window
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    {
        guard let scale = view.layer?.contentsScale else { return }
        makeScreenTextures(size: size, scale: scale)
    }
    
    // ---------------------------------------------------------------------------------
    // rotateTextures                                                         private
    // ---------------------------------------------------------------------------------
    // rotate the texture queue
    private func rotateTextures()
    {
        currentTexture = textureQueue.first
        textureQueue.remove(at: 0)
        textureQueue.append(currentTexture)
    }
}

