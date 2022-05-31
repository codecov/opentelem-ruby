
class Hello
    def getHello()
        return "Hello"
    end
end



describe Hello do
    it "gets hello" do 
        h = Hello.new
        expect(h.getHello()).to eq("Hello")
    end
end
